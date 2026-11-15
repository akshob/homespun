// SPDX-License-Identifier: AGPL-3.0-only

import { afterEach, describe, expect, it, vi } from "vitest";
import { EMAIL_DIAGNOSTICS_LIMIT, newReportId } from "../src/reports";
import diagnosticPayload from "./fixtures/diagnostic-payload.json";
import { APP, DEVICE, fakeMail, newInstall, objectText, post, rows, sendWith } from "./helpers";

const ID = /^HS-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$/;

interface ReportRow {
	id: string;
	install: string | null;
	received: string;
	app_version: string;
	build: string;
	channel: string;
	model: string;
	os: string;
	email: string | null;
	message: string;
	r2_key: string;
	status: string;
}

function report(changes: Record<string, unknown> = {}) {
	return {
		install: newInstall(),
		app: APP,
		device: DEVICE,
		message: "Free up stopped at 40 items.\nIt says the server copy is missing, but backup finished.",
		email: "jane@example.com",
		diagnostics: { lastRun: { items: 40, failed: 1 }, metricKit: diagnosticPayload },
		...changes,
	};
}

async function sendReport(body: Record<string, unknown>, mail = fakeMail()) {
	const response = await sendWith({ MAIL: mail.binding }, "POST", "/v1/reports", body);
	return { response, mail };
}

afterEach(() => {
	vi.restoreAllMocks();
});

describe("POST /v1/reports", () => {
	it("stores the report, emails it and returns its id", async () => {
		const body = report();
		const { response, mail } = await sendReport(body);
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		expect(id).toMatch(ID);

		const [row] = await rows<ReportRow>("SELECT * FROM reports WHERE id = ?1", id);
		expect(row).toMatchObject({
			install: body.install,
			app_version: "1.0",
			build: "42",
			channel: "testflight",
			model: "iPhone18,1",
			os: "27.2",
			email: "jane@example.com",
			message: body.message,
			r2_key: `reports/${id}.json`,
			status: "new",
		});
		expect(JSON.parse((await objectText(`reports/${id}.json`))!)).toEqual(body);

		expect(mail.sent).toHaveLength(1);
		const [email] = mail.sent;
		expect(email.from).toEqual({ email: "reports@homespun.photos", name: "Homespun Reports" });
		expect(email.to).toBe("owner@example.com");
		expect(email.replyTo).toBe("jane@example.com");
		expect(email.subject).toBe(`[Homespun ${id}] Free up stopped at 40 items. It says the server copy is miss`);
		expect(email.text).toContain(body.message);
		expect(email.text).toContain(`Report:   ${id}`);
		expect(email.text).toContain("Email:    jane@example.com");
		expect(email.text).toContain(`Install:  ${body.install}`);
		expect(email.text).toContain("App:      1.0 (42), testflight");
		expect(email.text).toContain("Device:   iPhone18,1 (iphone), OS 27.2");
		expect(email.text).toContain(`R2 reports/${id}.json`);
		expect(email.text).toContain('"terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11"');
		expect(email.text).not.toContain("truncated");
	});

	it("accepts a report without install, email or diagnostics", async () => {
		const { response, mail } = await sendReport({ install: null, app: APP, device: DEVICE, message: "Hi!" });
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		const [row] = await rows<ReportRow>("SELECT * FROM reports WHERE id = ?1", id);
		expect(row).toMatchObject({ install: null, email: null, message: "Hi!" });
		const [email] = mail.sent;
		expect(email).not.toHaveProperty("replyTo");
		expect(email.subject).toBe(`[Homespun ${id}] Hi!`);
		expect(email.text).toContain("Email:    (none given)");
		expect(email.text).toContain("Diagnostics: none attached");

		const empty = await sendReport({ app: APP, device: DEVICE, message: "No email", email: "  " });
		expect(empty.response.status).toBe(201);
		expect(empty.mail.sent[0]).not.toHaveProperty("replyTo");
	});

	it("keeps an unusual address in the body but not as Reply-To", async () => {
		const { response, mail } = await sendReport(report({ email: "jane,doe@example.com" }));
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		expect(mail.sent[0]).not.toHaveProperty("replyTo");
		expect(mail.sent[0].text).toContain("Email:    jane,doe@example.com");
		expect((await rows<ReportRow>("SELECT email FROM reports WHERE id = ?1", id))[0].email).toBe("jane,doe@example.com");
	});

	it("truncates large diagnostics in the email but stores them in full", async () => {
		const diagnostics = { log: Array.from({ length: 2000 }, (_, i) => `line ${i}: ${"x".repeat(20)}`) };
		const body = report({ diagnostics });
		const { response, mail } = await sendReport(body);
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		const text = mail.sent[0].text;
		expect(text).toContain(`Diagnostics (first ${EMAIL_DIAGNOSTICS_LIMIT} of`);
		expect(text).toContain(`[truncated, see reports/${id}.json]`);
		expect(text.length).toBeLessThan(EMAIL_DIAGNOSTICS_LIMIT + 2000);
		expect(JSON.parse((await objectText(`reports/${id}.json`))!).diagnostics).toEqual(diagnostics);
	});

	it("still stores the report and returns 201 when the email fails", async () => {
		const error = vi.spyOn(console, "error").mockImplementation(() => {});
		const { response, mail } = await sendReport(report(), fakeMail({ fail: true }));
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		expect(mail.sent).toHaveLength(1);
		expect(await rows("SELECT id FROM reports WHERE id = ?1", id)).toHaveLength(1);
		expect(await objectText(`reports/${id}.json`)).not.toBeNull();
		expect(error).toHaveBeenCalledWith(expect.stringContaining(`report ${id}: email failed: E_RECIPIENT_NOT_ALLOWED`));
	});

	it("skips the email when REPORT_TO is not set", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		const mail = fakeMail();
		const response = await sendWith({ MAIL: mail.binding, REPORT_TO: undefined }, "POST", "/v1/reports", report());
		expect(response.status).toBe(201);
		expect(mail.sent).toHaveLength(0);
		expect(warn).toHaveBeenCalledWith(expect.stringContaining("email skipped"));
	});

	it("sends through the configured send_email binding", async () => {
		const error = vi.spyOn(console, "error");
		const warn = vi.spyOn(console, "warn");
		const response = await post("/v1/reports", report());
		expect(response.status).toBe(201);
		expect((await response.json<{ id: string }>()).id).toMatch(ID);
		expect(error).not.toHaveBeenCalled();
		expect(warn).not.toHaveBeenCalled();
	});

	it("flattens the subject to one line of 60 characters", async () => {
		const message = "Line one\r\n\tline two\u0007 " + "é".repeat(80);
		const { response, mail } = await sendReport(report({ message }));
		const { id } = await response.json<{ id: string }>();
		expect(mail.sent[0].subject).toBe(`[Homespun ${id}] Line one line two ${"é".repeat(42)}`);
	});

	it.each([
		["an empty message", { message: "" }, "message: required"],
		["a blank message", { message: " \n " }, "message: required"],
		["a missing message", { message: undefined }, "message: required"],
		["a long message", { message: "x".repeat(5001) }, "message: longer than 5000 characters"],
		["a bad email", { email: "jane at example.com" }, "email: not a valid email address"],
		["an email without domain dot", { email: "jane@localhost" }, "email: not a valid email address"],
		["an email with two @", { email: "jane@doe@example.com" }, "email: not a valid email address"],
		["an email with a newline", { email: "jane@example.com\nBcc: x@example.com" }, "email: not a valid email address"],
		["a long email", { email: `${"j".repeat(250)}@example.com` }, "email: not a valid email address"],
		["a numeric email", { email: 42 }, "email: must be a string"],
		["diagnostics as an array", { diagnostics: [1, 2] }, "diagnostics: must be an object"],
		["a bad install", { install: "not-a-uuid" }, "install: must be a lowercase UUID or null"],
		["a missing app", { app: undefined }, "app: required"],
		["an extra field", { photo: "IMG_0001.HEIC" }, 'body: unknown field "photo"'],
	])("rejects %s", async (_, changes, error) => {
		const { response, mail } = await sendReport(report(changes));
		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error });
		expect(mail.sent).toHaveLength(0);
	});

	it("counts message length in characters", async () => {
		const flags = "🇳🇱".repeat(5000);
		expect((await sendReport(report({ message: flags }))).response.status).toBe(201);
		expect((await sendReport(report({ message: `${flags}!` }))).response.status).toBe(400);
	});

	it("generates ids from the unambiguous alphabet", () => {
		const ids = new Set(Array.from({ length: 2000 }, () => newReportId()));
		for (const id of ids) expect(id).toMatch(ID);
		expect(ids.size).toBeGreaterThan(1990);
	});
});
