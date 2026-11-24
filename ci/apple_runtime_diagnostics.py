# SPDX-License-Identifier: Apache-2.0
"""Hosted-only Apple package sampling and allowlisted synthetic UI-server evidence."""
import argparse
from contextlib import closing
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in
                ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid",
                 "svuid", "svgid", "reserved")] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in ("nfiles", "pgid", "jobc", "tdev", "tpgid")] + [
        ("nice", ctypes.c_int32), ("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


def identity(pid):
    if sys.platform != "darwin" or pid <= 0:
        return None
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                    ctypes.c_void_p, ctypes.c_int]
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    info, path = BSDInfo(), ctypes.create_string_buffer(4096)
    if library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    if info.pid != pid or library.proc_pidpath(pid, path, len(path)) <= 0:
        return None
    return {"pid": pid, "ppid": info.ppid, "birth": [info.seconds, info.microseconds],
            "exe": os.fsdecode(path.value)}


def same(current, expected):
    return bool(current and expected and current["pid"] == expected["pid"]
                and current["birth"] == expected["birth"]
                and (not expected.get("exe") or current["exe"] == expected["exe"]))


def owned(target, owner):
    if not target or not owner:
        return False
    if not same(identity(owner["pid"]), owner) or not same(identity(target["pid"]), target):
        return False
    current = target
    for _ in range(64):
        if current["pid"] == owner["pid"]:
            return True
        current = identity(current["ppid"])
        if not current:
            break
    return False


def sample_owned(target, owner, destination):
    if not owned(target, owner):
        return "refused_not_owned"
    pending = destination.with_suffix(".pending")
    try:
        sampled = subprocess.run(["/usr/bin/sample", str(target["pid"]), "2", "10",
                                  "-file", str(pending)], capture_output=True, timeout=8)
        # sample takes a numeric PID: never publish a report if its high-resolution
        # birth identity or ancestry changed across capture.
        if not owned(target, owner):
            return "discarded_identity_changed"
        if sampled.returncode != 0:
            destination.with_suffix(".error.txt").write_bytes(sampled.stderr[:4096])
            return f"sample_exit_{sampled.returncode}"
        pending.replace(destination)
        return "captured"
    except subprocess.TimeoutExpired:
        return "sample_timeout"
    finally:
        pending.unlink(missing_ok=True)


TABLES = {
    "assets": "id kind state hold_compact permanent purging generation device_compresses created_at updated_at imported_at trashed_at",
    "resources": "asset_id role size sha256 state received_bytes generation verified_at",
    "compact": "asset_id role size sha256",
    "jobs": "id type asset_id status attempts available_at lease_expires_at generation fence created_at",
    "backup_requests": "id manifest_id source wants_compact compact_state paused cancelled derivative_id revision",
    "backup_objects": "manifest_id role size sha256",
    "backup_jobs": "id manifest_id generation lane status attempts available_at expires_at fence",
}
PARTIAL = re.compile(r"(?:v2-[0-9a-f-]{36}|[0-9a-f]{64}-[a-z_]+)\.partial")
COMPACT_FOLDER = re.compile(r"(?:[0-9a-f]{64}(?:-[0-9a-f-]{36})?|v2-[0-9a-f-]{36})", re.I)
MEDIA_PARTIAL = re.compile(r"\.partial-(?:IMG|RECENT|DATED)_[0-9]+\.(?:heic|jpe?g|mov|mp4)", re.I)


def state_snapshot(data):
    result = {"tables": {}, "partials": []}
    database = data / "homespun.db"
    if database.is_symlink():
        raise ValueError("Refusing a symlinked catalog.")
    if database.exists():
        began = time.monotonic()
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=1)) as connection:
            connection.execute("PRAGMA query_only=ON")
            connection.set_progress_handler(lambda: int(time.monotonic() - began > 2), 1000)
            connection.execute("BEGIN")
            for table, allowed in TABLES.items():
                columns = {row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')}
                selected = [column for column in allowed.split() if column in columns]
                if selected:
                    names = ", ".join(f'"{column}"' for column in selected)
                    rows = connection.execute(f'SELECT {names} FROM "{table}" LIMIT 200').fetchall()
                    result["tables"][table] = [dict(zip(selected, row)) for row in rows]
    staging = data / "staging"
    if staging.is_dir() and not staging.is_symlink():
        for file in sorted(staging.iterdir())[:200]:
            if PARTIAL.fullmatch(file.name) and not file.is_symlink() and file.is_file():
                result["partials"].append({"filename": file.name, "bytes": file.stat().st_size})
    compact = data / "compact"
    if compact.is_dir() and not compact.is_symlink():
        for folder in sorted(compact.iterdir())[:200]:
            if not COMPACT_FOLDER.fullmatch(folder.name) or folder.is_symlink() or not folder.is_dir():
                continue
            for file in sorted(folder.iterdir())[:20]:
                if MEDIA_PARTIAL.fullmatch(file.name) and not file.is_symlink() and file.is_file():
                    result["partials"].append({"directory": folder.name, "filename": file.name,
                                               "bytes": file.stat().st_size})
    return result


def synthetic_path(data, state):
    data, servers = data.resolve(), (state / "servers").resolve()
    if data == servers or not data.is_relative_to(servers):
        raise ValueError("Refusing data outside this CI synthetic-server tree.")
    return data


def record_server(args):
    data = synthetic_path(args.data, args.state)
    synthetic_path(args.record.parent, args.state)
    if args.record.is_symlink() or args.record.with_suffix(".next").is_symlink():
        raise ValueError("Refusing a symlinked diagnostic record.")
    owner, server = identity(args.owner), identity(args.pid)
    if not owner or not server or not owned(server, owner) or Path(server["exe"]).resolve() != args.binary.resolve():
        raise ValueError("Refusing an unowned or unexpected test-server executable.")
    pending = args.record.with_suffix(".next")
    pending.write_text(json.dumps({"owner": owner, "server": server, "data": str(data)}))
    pending.replace(args.record)


def capture_server(args):
    base = synthetic_path(args.data, args.state)
    if args.record.is_symlink() or not args.record.resolve().is_relative_to(base):
        raise ValueError("Diagnostic record is outside this synthetic run.")
    record = json.loads(args.record.read_text())
    if args.owner != record["owner"]["pid"] or not same(identity(args.owner), record["owner"]):
        raise ValueError("Synthetic-server owner identity changed.")
    data = synthetic_path(Path(record["data"]), args.state)
    if not data.is_relative_to(base):
        raise ValueError("Recorded server data is outside this run.")
    args.output.mkdir(parents=True, exist_ok=True)
    # State comes first so a cancelled cleanup can still retain the small safe projection.
    try:
        snapshot = state_snapshot(data)
    except (OSError, sqlite3.Error):
        snapshot = {"state_capture": "unavailable"}
    (args.output / "server-state.json").write_text(json.dumps(snapshot, indent=2) + "\n")
    status = sample_owned(record["server"], record["owner"], args.output / "server.sample.txt")
    (args.output / "capture.json").write_text(json.dumps({"sample": status}) + "\n")


def descendants(owner):
    listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True, timeout=2)
    pairs = [tuple(map(int, row.split())) for row in listing.splitlines() if row.strip()]
    found = {owner["pid"]}
    ordered = []
    for _ in range(64):
        added = {pid for pid, parent in pairs if parent in found} - found
        if not added:
            break
        ordered.extend(sorted(added))
        found.update(added)
    return [current for pid in ordered
            if (current := identity(pid)) and owned(current, owner)]


def package():
    output = Path("ci-results/apple-runtime/package")
    output.mkdir(parents=True, exist_ok=True)
    with Path("package.log").open("wb") as log, Path("package.log").open("rb") as reader:
        process = subprocess.Popen(["swift", "test", "--skip-build"], stdout=log,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        owner = identity(process.pid)
        if not owner:
            process.kill()
            process.wait(timeout=5)
            raise RuntimeError("Cannot establish package command birth identity.")
        owner.pop("exe")  # Swift's driver may exec SwiftPM, retaining the same owned birth.
        began, next_heartbeat = time.monotonic(), time.monotonic() + 15
        timed_out = False
        try:
            while process.poll() is None:
                data = reader.read()
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                now = time.monotonic()
                if now >= next_heartbeat:
                    print(f"[Apple package] +{int(now - began)}s", flush=True)
                    next_heartbeat = now + 15
                if now - began >= 300:
                    timed_out = True
                    samples = []
                    children = descendants(owner)
                    for child in children:
                        if (Path(child["exe"]).name in ("xctest", "HomespunPackageTests")
                                or Path(child["exe"]).name.endswith(".xctest")):
                            samples.append({"pid": child["pid"], "sample": sample_owned(
                                child, owner, output / f"xctest-{child['pid']}.sample.txt")})
                    if not samples:
                        samples.append({"pid": process.pid, "sample": sample_owned(
                            identity(process.pid), owner, output / "swiftpm.sample.txt")})
                    (output / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
                    break
                time.sleep(0.5)
        finally:
            # Only still-matching descendants of our unreaped direct command are signaled.
            try:
                if process.poll() is None:
                    for child in reversed(descendants(owner)):
                        if owned(child, owner):
                            try:
                                os.kill(child["pid"], signal.SIGKILL)
                            except ProcessLookupError:
                                pass
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
            sys.stdout.buffer.write(reader.read())
            sys.stdout.buffer.flush()
    status = 124 if timed_out else process.returncode
    if "✘" in Path("package.log").read_text(errors="replace"):
        status = status or 1
    (output / "result.json").write_text(json.dumps({"status": status, "timed_out": timed_out}) + "\n")
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("package")
    for name in ("record", "capture"):
        command = commands.add_parser(name)
        for option in ("data", "state", "record"):
            command.add_argument("--" + option, type=Path, required=True)
        command.add_argument("--owner", type=int, required=True)
        if name == "record":
            command.add_argument("--pid", type=int, required=True)
            command.add_argument("--binary", type=Path, required=True)
        else:
            command.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        raise RuntimeError("Apple evidence capture is restricted to GitHub-hosted macOS synthetic tests.")
    if args.command == "package":
        return package()
    if args.command == "record":
        record_server(args)
    else:
        capture_server(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
