# SPDX-License-Identifier: Apache-2.0
"""Bounded Linux test diagnostics; never used by the product or a real server."""
from pathlib import Path
import json
import os
import resource
import select
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path("ci-results/server-runtime")
PHASES = [
    ("process-io", 45, "processRunnerDrainsBothPipesAndBoundsDiagnostics"),
    ("process-cancel", 45, "processCancellationTerminatesAndReapsOnlyItsOwnedChild"),
    ("process-progress", 45, "stalledProcessProgressFailsWithoutATotalRuntimeLimit"),
    ("full", 300, None),
]
BACKTRACE = ("enable=yes,interactive=no,color=no,threads=all,registers=none,"
             "images=mentioned,sanitize=yes,limit=128,timeout=10s")


def read_at(directory, name, maximum=65536):
    descriptor = os.open(name, os.O_RDONLY | os.O_CLOEXEC, dir_fd=directory)
    with os.fdopen(descriptor, "rb") as file:
        return file.read(maximum).decode(errors="replace")


def process_stat(text):
    # comm may contain spaces and parentheses. The fields after its final ')' are
    # state (3), parent (4), ..., starttime (22).
    fields = text.rsplit(")", 1)[1].split()
    return int(fields[1]), int(fields[19])


class OwnedProcess:
    def __init__(self, pid, descriptor, directory, started):
        self.pid = pid
        self.descriptor = descriptor
        self.directory = directory
        self.started = started

    @classmethod
    def open(cls, pid, parent=None):
        directory = descriptor = None
        try:
            directory = os.open(f"/proc/{pid}", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
            actual_parent, started = process_stat(read_at(directory, "stat"))
            if parent is not None and actual_parent != parent:
                return None
            descriptor = os.pidfd_open(pid, 0)
            if process_stat(read_at(directory, "stat"))[1] != started:
                return None
            process = cls(pid, descriptor, directory, started)
            directory = descriptor = None
            return process
        except (OSError, ValueError, IndexError) as error:
            if parent is None:
                raise RuntimeError(f"Cannot acquire the launched command's procfs/pidfd: {error}") from error
            return None
        finally:
            for handle in (directory, descriptor):
                if handle is not None:
                    os.close(handle)

    def alive(self):
        watcher = select.poll()
        watcher.register(self.descriptor, select.POLLIN)
        return not watcher.poll(0)

    def send(self, number):
        try:
            # A pidfd targets this exact descendant even if its numeric PID is reused.
            signal.pidfd_send_signal(self.descriptor, number, None, 0)
        except ProcessLookupError:
            pass

    def exe(self):
        try:
            return os.readlink("exe", dir_fd=self.directory)
        except OSError:
            return ""

    def entries(self, relative):
        descriptor = os.open(relative, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
                             dir_fd=self.directory)
        try:
            return os.listdir(descriptor)
        finally:
            os.close(descriptor)

    def children(self):
        children = set()
        try:
            # A process can spawn from any worker thread, not only its main thread.
            for thread in self.entries("task"):
                try:
                    children.update(int(pid) for pid in read_at(
                        self.directory, f"task/{thread}/children").split())
                except OSError:
                    pass
        except OSError:
            pass
        return children

    def close(self):
        os.close(self.descriptor)
        os.close(self.directory)


class OwnedTree:
    def __init__(self, pid):
        root = OwnedProcess.open(pid)
        if root is None:
            raise RuntimeError("Cannot acquire the launched Swift command's pidfd.")
        self.processes = {pid: root}

    def refresh(self):
        for pid, process in list(self.processes.items()):
            if not process.alive():
                process.close()
                del self.processes[pid]
        pending = list(self.processes.values())
        while pending:
            parent = pending.pop()
            for pid in parent.children():
                if pid in self.processes:
                    continue
                child = OwnedProcess.open(pid, parent=parent.pid)
                if child is not None:
                    self.processes[pid] = child
                    pending.append(child)

    def close(self):
        for process in self.processes.values():
            process.close()
        self.processes.clear()


def snapshot(tree, destination):
    tree.refresh()
    with destination.open("w") as file:
        for process in sorted(tree.processes.values(), key=lambda item: item.pid):
            file.write(f"\n=== owned PID {process.pid}, starttime {process.started}, "
                       f"exe {process.exe()} ===\n")
            for name in ("status", "limits"):
                try:
                    file.write(f"\n{name}:\n{read_at(process.directory, name)}")
                except OSError as error:
                    file.write(f"{name}: {error}\n")
            try:
                for descriptor in process.entries("fd")[:256]:
                    try:
                        target = os.readlink(f"fd/{descriptor}", dir_fd=process.directory)
                        file.write(f"fd {descriptor}: {target}\n")
                    except OSError:
                        pass
                threads = sorted(process.entries("task"), key=int)
                file.write(f"\n{len(threads)} threads (first 256 kernel snapshots):\n")
                for thread in threads[:256]:
                    for name in ("comm", "wchan", "stack", "syscall"):
                        try:
                            value = read_at(process.directory, f"task/{thread}/{name}", 8192)
                            file.write(f"TID {thread} {name}: {value.rstrip()}\n")
                        except OSError as error:
                            file.write(f"TID {thread} {name}: {error}\n")
            except OSError as error:
                file.write(f"process exited during snapshot: {error}\n")


def flush_log(reader):
    data = reader.read()
    if data:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


def stop_owned(tree):
    try:
        tree.refresh()
    except OSError as error:
        print(f"Final descendant refresh failed: {error}", flush=True)
    # No process-name matching or process-group signals.
    # Keep handles to previously discovered children even if they became orphans.
    for process in reversed(list(tree.processes.values())):
        try:
            process.send(signal.SIGKILL)
        except OSError as error:
            print(f"Owned PID {process.pid} cleanup failed: {error}", flush=True)


def run_phase(name, maximum_seconds, selector, base):
    directory = base / name
    directory.mkdir(parents=True, exist_ok=True)
    backtraces = directory / "backtraces"
    backtraces.mkdir(exist_ok=True)
    log = Path("test.log") if selector is None else directory / "test.log"
    command = ["swift", "test", "--skip-build"]
    if selector is not None:
        command += ["--filter", selector]
    started = time.monotonic()
    tree = process = None
    timed_out = False
    print(f"\n=== {name}: {maximum_seconds}s diagnostic ceiling; "
          f"{selector or 'UNFILTERED FULL SUITE'} ===", flush=True)
    try:
        with log.open("wb") as output, log.open("rb") as reader:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output,
                                       stderr=subprocess.STDOUT,
                                       env={**os.environ, "SWIFT_BACKTRACE":
                                            BACKTRACE + f",output-to={backtraces}"})
            tree = OwnedTree(process.pid)
            heartbeat = started
            while process.poll() is None:
                tree.refresh()
                flush_log(reader)
                now = time.monotonic()
                if now - heartbeat >= 15:
                    print(f"[{name}] +{int(now - started)}s; owned PIDs "
                          f"{sorted(tree.processes)}", flush=True)
                    heartbeat = now
                if now - started >= maximum_seconds:
                    timed_out = True
                    print(f"[{name}] STALLED: capturing owned threads, signals and pipe FDs.",
                          flush=True)
                    snapshot(tree, directory / "before-quit.txt")
                    targets = [item for item in tree.processes.values()
                               if item.exe().endswith(".xctest")]
                    if not targets:
                        targets = [item for item in tree.processes.values()
                                   if item.pid == process.pid]
                    for target in targets:
                        print(f"[{name}] SIGQUIT to owned PID {target.pid} for Swift's "
                              "noninteractive all-thread crash backtrace.", flush=True)
                        target.send(signal.SIGQUIT)
                    # The runtime reporter is itself a descendant. Give it a bounded
                    # opportunity to finish, then retain a second kernel snapshot.
                    until = time.monotonic() + 20
                    while process.poll() is None and time.monotonic() < until:
                        tree.refresh()
                        flush_log(reader)
                        time.sleep(0.25)
                    snapshot(tree, directory / "after-quit.txt")
                    break
                time.sleep(0.25)
            flush_log(reader)
    finally:
        if tree is not None:
            stop_owned(tree)
        elif process is not None:
            # Only if acquiring procfs/pidfd ownership failed. This direct child has
            # never been polled/reaped, so its PID cannot have been reused.
            process.kill()
        if process is not None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                print(f"[{name}] owned Swift command did not reap after SIGKILL.", flush=True)
        if tree is not None:
            tree.close()
    text = log.read_text(errors="replace")
    matched = selector is None or f"{selector}() started." in text
    status = 124 if timed_out else process.returncode
    if not matched or "✘" in text:
        status = status or 1
    result = {"phase": name, "seconds": round(time.monotonic() - started, 2),
              "status": status, "timed_out": timed_out, "selection_started": matched}
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"[{name}] {result}", flush=True)
    return result


def run_all(base):
    base.mkdir(parents=True, exist_ok=True)
    results = []
    for name, seconds, selector in PHASES:
        try:
            result = run_phase(name, seconds, selector, base)
        except Exception as error:
            result = {"phase": name, "seconds": None, "status": 1,
                      "timed_out": False, "error": str(error)}
            print(f"[{name}] diagnostic infrastructure failed: {error}", flush=True)
        results.append(result)
    (base / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as file:
            file.write("### Server (Linux): runtime diagnostics\n\n"
                       "| Phase | Seconds | Exit | Timed out |\n|---|---:|---:|---|\n")
            for result in results:
                file.write(f"| {result['phase']} | {result['seconds']} | "
                           f"{result['status']} | {result['timed_out']} |\n")
            file.write("\nThe full phase is the original unfiltered suite. A diagnostic "
                       "timeout is a failure, never a skip/pass. See the server-runtime artifact.\n")
    return int(any(result["status"] != 0 for result in results))


def main():
    if sys.platform != "linux" or not all((
            hasattr(os, "pidfd_open"), hasattr(signal, "pidfd_send_signal"))):
        raise RuntimeError("Hosted Linux pidfd support is required; unsafe PID signaling is disabled.")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    ROOT.mkdir(parents=True, exist_ok=True)
    metadata = {name: shutil.which(name) for name in ("swift", "swift-backtrace", "swift-inspect", "lldb")}
    metadata["cpu_count"] = os.cpu_count()
    for path in ("/proc/self/limits", "/proc/self/status", "/proc/sys/kernel/yama/ptrace_scope",
                 "/sys/fs/cgroup/cpu.max", "/sys/fs/cgroup/pids.max", "/sys/fs/cgroup/pids.current",
                 "/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory.current"):
        try:
            metadata[path] = Path(path).read_text()
        except OSError as error:
            metadata[path] = str(error)
    (ROOT / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return run_all(ROOT)


if __name__ == "__main__":
    sys.exit(main())
