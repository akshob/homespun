// SPDX-License-Identifier: AGPL-3.0-only

import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { usageKeys } from "../src/budget";
import { threadFrames } from "../src/crashmail";
import diagnosticPayload from "./fixtures/diagnostic-payload.json";
import metricPayload from "./fixtures/metric-payload.json";
import { APP, DEVICE, fakeMail, newInstall, rows, sendWith } from "./helpers";

const frame = (binaryName: string, offset: number, subFrames?: unknown[]) => ({
	binaryUUID: `${binaryName.toUpperCase()}-UUID`,
	offsetIntoBinaryTextSegment: offset,
	sampleCount: 1,
	binaryName,
	address: 4_000_000_000 + offset,
	...(subFrames ? { subFrames } : {}),
});

const abortCrash = {
	crashDiagnostics: [
		{
			callStackTree: {
				callStackPerThread: true,
				callStacks: [
					{ threadAttributed: false, callStackRootFrames: [frame("libdispatch.dylib", 1)] },
					{
						threadAttributed: true,
						callStackRootFrames: [frame("libsystem_kernel.dylib", 10, [frame("CoreFoundation", 20, [frame("Homespun", 30)])])],
					},
				],
			},
			diagnosticMetaData: {
				exceptionType: 10,
				exceptionCode: 0,
				signal: 6,
				isTestFlightApp: true,
				terminationReason: "Namespace SIGNAL, Code 6 Abort trap: 6",
				objectiveCexceptionReason: {
					composedMessage: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
					formatString: "*** -[%@ %@]: object cannot be nil",
					arguments: ["__NSArrayM", "insertObject:atIndex:"],
					exceptionType: "ExceptionTypeNSException",
					className: "NSException",
					exceptionName: "NSInvalidArgumentException",
				},
			},
		},
	],
};

const hangOnly = {
	hangDiagnostics: [
		{
			callStackTree: { callStacks: [{ threadAttributed: true, callStackRootFrames: [frame("Homespun", 99)] }] },
			diagnosticMetaData: {
				hangDuration: "3.25 sec",
				appVersion: "0.1.0",
				appBuildVersion: "7",
				deviceType: "iPhone19,4",
				osVersion: "iPhone OS 27.2.1 (24C101)",
			},
		},
	],
};

function upload(payload: unknown, options: { install?: string; mail?: ReturnType<typeof fakeMail>; caps?: Record<string, string>; kind?: string } = {}) {
	const install = options.install ?? newInstall();
	const mail = options.mail ?? fakeMail();
	const body = { install, app: APP, device: DEVICE, payload };
	const response = sendWith({ MAIL: mail.binding, ...options.caps }, "POST", `/v1/${options.kind ?? "diagnostics"}`, body);
	return { response, mail, install };
}

async function usage(key: string): Promise<number | undefined> {
	return (await rows<{ value: number }>("SELECT value FROM usage WHERE key = ?1", key))[0]?.value;
}

beforeEach(async () => {
	await env.DB.batch([env.DB.prepare("DELETE FROM usage"), env.DB.prepare("DELETE FROM payloads")]);
});

afterEach(() => {
	vi.restoreAllMocks();
});

describe("crash emails", () => {
	it("email a crash with its subject, details and crashed thread", async () => {
		const { response, mail, install } = upload(diagnosticPayload);
		expect(await (await response).json()).toEqual({ accepted: 1 });
		const [{ r2_key: key }] = await rows<{ r2_key: string }>("SELECT r2_key FROM payloads WHERE install = ?1", install);

		expect(mail.sent).toHaveLength(1);
		const [email] = mail.sent;
		expect(email.from).toEqual({ email: "reports@homespun.photos", name: "Homespun Reports" });
		expect(email.to).toBe("owner@example.com");
		expect(email).not.toHaveProperty("replyTo");
		expect(email.subject).toBe("[Homespun crash] 1.0 (42) · iPhone18,1 · iOS 27.2 · SIGSEGV");
		expect(email.text).toBe(
			[
				"Crash in Homespun 1.0 (42), testflight; TestFlight: yes",
				"Device: iPhone18,1, iPhone OS 27.2 (25C51)",
				"",
				"In this payload: 1 crash, 0 hangs, 0 CPU exceptions, 0 disk-write exceptions, 0 app-launch diagnostics",
				"",
				"Termination reason: Namespace SIGNAL, Code 11 Segmentation fault: 11",
				"Exception: EXC_BAD_ACCESS (1), code 0, signal SIGSEGV (11)",
				"",
				"Crashed thread:",
				"  Homespun  +412316  (6A0B5F2C-8E4D-3B1A-9C7E-2F4D6B8A1C3E)",
				"  Homespun  +398004  (6A0B5F2C-8E4D-3B1A-9C7E-2F4D6B8A1C3E)",
				"  SwiftUI  +23116  (0F1E2D3C-4B5A-3968-8776-655443322110)",
				"",
				`Stored:  R2 ${key}`,
				`         wrangler r2 object get homespun-telemetry/${key} --remote --file diagnostics.json`,
				`Install: ${install}`,
				"",
			].join("\n"),
		);
		// Nothing else from the payload: no other threads, memory map, pid or bundle id.
		for (const absent of ["libsystem_kernel", "REGION", "4127", "photos.homespun.app", "regionFormat"]) {
			expect(email.text).not.toContain(absent);
		}

		const today = usageKeys(new Date());
		expect(await usage(today.dayEmails)).toBe(1);
		expect(await usage(today.dayCrashEmails)).toBe(1);
		// Row/indexes, journal reservation, two transient fences, and seven counters.
		expect(await usage(today.dayWrites)).toBe(4 + 12 + 4 + 7);
	});

	it("fall back to the request's app and device, and show the Objective-C exception", async () => {
		const body = {
			install: newInstall(),
			app: { version: "0.1.0", build: "202611151609", channel: "testflight" },
			device: { model: "iPhone19,4", os: "27.2.1", family: "iphone" },
			payload: abortCrash,
		};
		const mail = fakeMail();
		expect((await sendWith({ MAIL: mail.binding }, "POST", "/v1/diagnostics", body)).status).toBe(202);
		const [email] = mail.sent;
		expect(email.subject).toBe("[Homespun crash] 0.1.0 (202611151609) · iPhone19,4 · iOS 27.2.1 · SIGABRT");
		expect(email.text).toContain("Device: iPhone19,4, iOS 27.2.1");
		expect(email.text).toContain("Exception: EXC_CRASH (10), code 0, signal SIGABRT (6)");
		expect(email.text).toContain(
			"Objective-C exception: NSInvalidArgumentException: *** -[__NSArrayM insertObject:atIndex:]: object cannot be nil (class NSException)",
		);
		expect(email.text).toContain("Crashed thread:\n  libsystem_kernel.dylib  +10  (LIBSYSTEM_KERNEL.DYLIB-UUID)\n  CoreFoundation  +20");
		expect(email.text).not.toContain("libdispatch");
	});

	it("say hang when there are only hangs", async () => {
		const { response, mail } = upload(hangOnly);
		expect((await response).status).toBe(202);
		const [email] = mail.sent;
		expect(email.subject).toBe("[Homespun hang] 0.1.0 (7) · iPhone19,4 · iOS 27.2.1 · 3.25 sec");
		expect(email.text).toContain("Hang in Homespun 0.1.0 (7), testflight; TestFlight: unknown");
		expect(email.text).toContain("In this payload: 0 crashes, 1 hang,");
		expect(email.text).toContain("Hang duration: 3.25 sec\n\nHanging thread:\n  Homespun  +99  (HOMESPUN-UUID)\n");
		expect(email.text).not.toContain("Termination reason");
	});

	it("are not sent for metrics or for diagnostics without crashes or hangs", async () => {
		const metrics = upload(metricPayload, { kind: "metrics" });
		expect((await metrics.response).status).toBe(202);
		const quiet = upload({ cpuExceptionDiagnostics: [{}], diskWriteExceptionDiagnostics: [{}] });
		expect((await quiet.response).status).toBe(202);
		expect([...metrics.mail.sent, ...quiet.mail.sent]).toHaveLength(0);
		expect(await usage(usageKeys(new Date()).dayCrashEmails)).toBeUndefined();
	});

	it("are sent once per install and day", async () => {
		const install = newInstall();
		const mail = fakeMail();
		for (const payload of [diagnosticPayload, hangOnly, abortCrash]) {
			expect((await upload(payload, { install, mail }).response).status).toBe(202);
		}
		expect(mail.sent).toHaveLength(1);
		expect(await rows("SELECT id FROM payloads WHERE install = ?1", install)).toHaveLength(3);

		expect((await upload(diagnosticPayload, { mail }).response).status).toBe(202);
		expect(mail.sent).toHaveLength(2);
		expect(await usage(usageKeys(new Date()).dayCrashEmails)).toBe(2);
	});

	it("stop at the daily crash email cap", async () => {
		const mail = fakeMail();
		const caps = { CRASH_EMAILS_MAX_DAY: "2" };
		for (let i = 0; i < 3; i++) expect((await upload(diagnosticPayload, { mail, caps }).response).status).toBe(202);
		expect(mail.sent).toHaveLength(2);
		expect(await rows("SELECT id FROM payloads")).toHaveLength(3);
		expect(await usage(usageKeys(new Date()).dayCrashEmails)).toBe(2);
		expect(await usage(usageKeys(new Date()).dayEmails)).toBe(2);
	});

	it("share the daily email cap with reports", async () => {
		const today = usageKeys(new Date());
		await env.DB.prepare("INSERT INTO usage (key, value) VALUES (?1, 50)").bind(today.dayEmails).run();
		const { response, mail, install } = upload(diagnosticPayload);
		expect(await (await response).json()).toEqual({ accepted: 1 });
		expect(mail.sent).toHaveLength(0);
		expect(await rows("SELECT id FROM payloads WHERE install = ?1", install)).toHaveLength(1);
		expect(await usage(today.dayEmails)).toBe(50);
		expect(await usage(today.dayCrashEmails)).toBeUndefined();
	});

	it("never fail the upload when sending fails", async () => {
		const error = vi.spyOn(console, "error").mockImplementation(() => {});
		const { response, mail, install } = upload(diagnosticPayload, { mail: fakeMail({ fail: true }) });
		expect(await (await response).json()).toEqual({ accepted: 1 });
		expect(mail.sent).toHaveLength(1);
		expect(await rows("SELECT id FROM payloads WHERE install = ?1", install)).toHaveLength(1);
		expect(error).toHaveBeenCalledWith(expect.stringContaining("crash email for diagnostics/"));
	});
});

describe("threadFrames", () => {
	it("flattens the attributed thread depth-first", () => {
		const tree = {
			callStacks: [
				{ threadAttributed: true, callStackRootFrames: [frame("A", 1, [frame("B", 2, [frame("C", 3)]), frame("D", 4)]), frame("E", 5)] },
			],
		};
		expect(threadFrames(tree).map((line) => line.split(" ")[0])).toEqual(["A", "B", "C", "D", "E"]);
		expect(threadFrames({ callStacks: [{ threadAttributed: false, callStackRootFrames: [frame("A", 1)] }] })).toEqual([]);
		expect(threadFrames(undefined)).toEqual([]);
		expect(threadFrames({ callStacks: [{ threadAttributed: true, callStackRootFrames: [{}] }] })).toEqual(["?  +?  (?)"]);
	});

	it("shows at most 60 frames", () => {
		let chain: Record<string, unknown> = frame("Homespun", 100);
		for (let i = 99; i > 0; i--) chain = frame("Homespun", i, [chain]);
		const lines = threadFrames({ callStacks: [{ threadAttributed: true, callStackRootFrames: [chain] }] });
		expect(lines).toHaveLength(61);
		expect(lines[0]).toBe("Homespun  +1  (HOMESPUN-UUID)");
		expect(lines[59]).toBe("Homespun  +60  (HOMESPUN-UUID)");
		expect(lines[60]).toBe("… 40 more frames");
	});
});
