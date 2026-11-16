// SPDX-License-Identifier: AGPL-3.0-only

import { isObject } from "./http";
import type { DiagnosticSummary } from "./payloads";
import { REPORT_FROM } from "./reports";
import type { AppInfo, DeviceInfo } from "./validate";

/** Lines of the crashed (or hanging) thread's call stack shown in the email. */
export const MAX_FRAME_LINES = 60;

const SIGNALS: Record<number, string> = {
	1: "SIGHUP",
	2: "SIGINT",
	3: "SIGQUIT",
	4: "SIGILL",
	5: "SIGTRAP",
	6: "SIGABRT",
	7: "SIGEMT",
	8: "SIGFPE",
	9: "SIGKILL",
	10: "SIGBUS",
	11: "SIGSEGV",
	12: "SIGSYS",
	13: "SIGPIPE",
	14: "SIGALRM",
	15: "SIGTERM",
};

/** Mach exception types (`exceptionType` in MetricKit). */
const EXCEPTIONS: Record<number, string> = {
	1: "EXC_BAD_ACCESS",
	2: "EXC_BAD_INSTRUCTION",
	3: "EXC_ARITHMETIC",
	4: "EXC_EMULATION",
	5: "EXC_SOFTWARE",
	6: "EXC_BREAKPOINT",
	7: "EXC_SYSCALL",
	8: "EXC_MACH_SYSCALL",
	9: "EXC_RPC_ALERT",
	10: "EXC_CRASH",
	11: "EXC_RESOURCE",
	12: "EXC_GUARD",
	13: "EXC_CORPSE_NOTIFY",
};

export interface CrashNotice {
	install: string;
	r2Key: string;
	app: AppInfo;
	device: DeviceInfo;
	payload: Record<string, unknown>;
	summary: DiagnosticSummary;
}

export function signalName(signal: number): string {
	return SIGNALS[signal] ?? `signal ${signal}`;
}

export function exceptionName(type: number): string {
	return EXCEPTIONS[type] ?? `exception type ${type}`;
}

/**
 * A short notice about the first crash (or, without crashes, the first hang) of a diagnostics
 * payload. Uses only the fields listed in README "Emails you receive", nothing else from the payload.
 */
export function crashEmail(notice: CrashNotice): { subject: string; text: string } {
	const { summary, payload } = notice;
	const crash = summary.crashDiagnostics > 0;
	const diagnostic = first(payload[crash ? "crashDiagnostics" : "hangDiagnostics"]);
	const meta = isObject(diagnostic?.diagnosticMetaData) ? diagnostic.diagnosticMetaData : {};

	const version = clean(meta.appVersion, 32) ?? notice.app.version;
	const build = clean(meta.appBuildVersion, 32) ?? notice.app.build;
	const model = clean(meta.deviceType, 32) ?? notice.device.model;
	const osVersion = clean(meta.osVersion, 64);
	const os = `iOS ${osVersion?.match(/\d+(?:\.\d+)+/)?.[0] ?? notice.device.os}`;
	const signal = number(meta.signal);
	const exceptionType = number(meta.exceptionType);
	const exceptionCode = number(meta.exceptionCode);
	const hangDuration = clean(meta.hangDuration, 32);

	const last = crash ? (signal !== undefined ? signalName(signal) : undefined) : hangDuration;
	const subject = [`[Homespun ${crash ? "crash" : "hang"}] ${version} (${build})`, model, os, ...(last ? [last] : [])].join(" · ");

	const testFlight = typeof meta.isTestFlightApp === "boolean" ? (meta.isTestFlightApp ? "yes" : "no") : "unknown";
	const lines = [
		`${crash ? "Crash" : "Hang"} in Homespun ${version} (${build}), ${notice.app.channel}; TestFlight: ${testFlight}`,
		`Device: ${model}, ${osVersion ?? os}`,
		"",
		`In this payload: ${count(summary.crashDiagnostics, "crash", "crashes")}, ${count(summary.hangDiagnostics, "hang", "hangs")}, ` +
			`${count(summary.cpuExceptionDiagnostics, "CPU exception", "CPU exceptions")}, ` +
			`${count(summary.diskWriteExceptionDiagnostics, "disk-write exception", "disk-write exceptions")}, ` +
			`${count(summary.appLaunchDiagnostics, "app-launch diagnostic", "app-launch diagnostics")}`,
		"",
	];
	if (crash) {
		const termination = clean(meta.terminationReason, 300);
		if (termination) lines.push(`Termination reason: ${termination}`);
		const exception = [
			exceptionType !== undefined ? `${exceptionName(exceptionType)} (${exceptionType})` : undefined,
			exceptionCode !== undefined ? `code ${exceptionCode}` : undefined,
			signal !== undefined ? `signal ${signalName(signal)} (${signal})` : undefined,
		].filter(Boolean);
		if (exception.length > 0) lines.push(`Exception: ${exception.join(", ")}`);
		const reason = exceptionReason(meta);
		if (reason) lines.push(`Objective-C exception: ${reason}`);
	} else if (hangDuration) {
		lines.push(`Hang duration: ${hangDuration}`);
	}

	const frames = threadFrames(diagnostic?.callStackTree);
	lines.push("", `${crash ? "Crashed" : "Hanging"} thread:`);
	lines.push(...(frames.length > 0 ? frames.map((frame) => `  ${frame}`) : ["  (no call stack)"]));
	lines.push(
		"",
		`Stored:  R2 ${notice.r2Key}`,
		`         wrangler r2 object get homespun-telemetry/${notice.r2Key} --remote --file diagnostics.json`,
		`Install: ${notice.install}`,
		"",
	);
	return { subject, text: lines.join("\n") };
}

/** Sends the notice; a failure is only logged. */
export async function sendCrashEmail(env: Env, notice: CrashNotice): Promise<void> {
	const to = env.REPORT_TO?.trim();
	if (!to || !env.MAIL) return;
	try {
		await env.MAIL.send({ from: REPORT_FROM, to, ...crashEmail(notice) });
	} catch (error) {
		console.error(`crash email for ${notice.r2Key} failed: ${error instanceof Error ? error.message : String(error)}`);
	}
}

/** The thread with `threadAttributed: true`, flattened depth-first, at most MAX_FRAME_LINES lines. */
export function threadFrames(tree: unknown): string[] {
	const stacks = isObject(tree) && Array.isArray(tree.callStacks) ? tree.callStacks : [];
	const thread = stacks.find((stack) => isObject(stack) && stack.threadAttributed === true);
	const roots = isObject(thread) && Array.isArray(thread.callStackRootFrames) ? thread.callStackRootFrames : [];
	const lines: string[] = [];
	const pending: unknown[] = [...roots].reverse();
	let total = 0;
	while (pending.length > 0) {
		const frame = pending.pop();
		if (!isObject(frame)) continue;
		total++;
		if (lines.length < MAX_FRAME_LINES) {
			const binary = clean(frame.binaryName, 80) ?? "?";
			const offset = number(frame.offsetIntoBinaryTextSegment) ?? "?";
			const uuid = clean(frame.binaryUUID, 40) ?? "?";
			lines.push(`${binary}  +${offset}  (${uuid})`);
		}
		if (Array.isArray(frame.subFrames)) pending.push(...[...frame.subFrames].reverse());
	}
	if (total > lines.length) lines.push(`… ${total - lines.length} more frames`);
	return lines;
}

function exceptionReason(meta: Record<string, unknown>): string | undefined {
	const reason = isObject(meta.objectiveCexceptionReason)
		? meta.objectiveCexceptionReason
		: isObject(meta.exceptionReason)
			? meta.exceptionReason
			: undefined;
	if (!reason) return undefined;
	const name = clean(reason.exceptionName, 100);
	const message = clean(reason.composedMessage, 500);
	const className = clean(reason.className, 100);
	const text = [name, message].filter(Boolean).join(": ");
	if (!text && !className) return undefined;
	return className ? `${text || "?"} (class ${className})` : text;
}

function first(list: unknown): Record<string, unknown> | undefined {
	return Array.isArray(list) && isObject(list[0]) ? list[0] : undefined;
}

/** A payload string on one line and at most `max` characters, or undefined. */
function clean(value: unknown, max: number): string | undefined {
	if (typeof value !== "string") return undefined;
	const text = value.replace(/[\s\u0000-\u001f\u007f]+/g, " ").trim();
	return text === "" ? undefined : Array.from(text).slice(0, max).join("");
}

function number(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function count(n: number, one: string, many: string): string {
	return `${n} ${n === 1 ? one : many}`;
}
