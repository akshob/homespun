// SPDX-License-Identifier: AGPL-3.0-only

import { badRequest, isObject, json, type JsonBody } from "./http";
import { isInstall, onlyKeys, parseApp, parseDevice, type AppInfo, type DeviceInfo } from "./validate";

/** Unambiguous symbols for report ids: no 0/O, 1/I/L. */
export const REPORT_ID_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
export const REPORT_FROM = { email: "reports@homespun.photos", name: "Homespun Reports" };
export const MAX_MESSAGE = 5000;
export const MAX_EMAIL = 254;
/** Characters of pretty-printed diagnostics included in the email; the rest stays in R2. */
export const EMAIL_DIAGNOSTICS_LIMIT = 20_000;

/** Same rule as the app's form, so anything it lets through is accepted. */
const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
/** Stricter shape required before an address is used as Reply-To; others appear only in the body. */
const REPLY_TO_PATTERN = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:".]+(\.[^\s@<>()[\]\\,;:".]+)+$/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;
const ID_ATTEMPTS = 5;

const INSERT_REPORT = `INSERT INTO reports
	(id, install, received, app_version, build, channel, model, os, email, message, r2_key, status)
	VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'new')`;

interface Report {
	id: string;
	received: string;
	r2Key: string;
	install: string | null;
	app: AppInfo;
	device: DeviceInfo;
	message: string;
	email: string | null;
	diagnostics: Record<string, unknown> | null;
}

/** POST /v1/reports: stores the report (R2 + D1), then emails it. Email failures are only logged. */
export async function handleReport(body: JsonBody, env: Env): Promise<Response> {
	const { value } = body;
	onlyKeys(value, ["install", "app", "device", "message", "email", "diagnostics"], "body");
	const install = value.install ?? null;
	if (install !== null && !isInstall(install)) badRequest("install: must be a lowercase UUID or null");
	const app = parseApp(value.app);
	const device = parseDevice(value.device);
	const message = parseMessage(value.message);
	const email = parseEmail(value.email);
	const diagnostics = value.diagnostics ?? null;
	if (diagnostics !== null && !isObject(diagnostics)) badRequest("diagnostics: must be an object");

	const received = new Date().toISOString();
	const id = await insertWithUniqueId(env, (candidate) =>
		env.DB.prepare(INSERT_REPORT).bind(
			candidate,
			install,
			received,
			app.version,
			app.build,
			app.channel,
			device.model,
			device.os,
			email,
			message,
			reportKey(candidate),
		),
	);
	const r2Key = reportKey(id);
	try {
		await env.BUCKET.put(r2Key, body.text, { httpMetadata: { contentType: "application/json" } });
	} catch (error) {
		await env.DB.prepare("DELETE FROM reports WHERE id = ?1").bind(id).run().catch(() => {});
		throw error;
	}

	await sendReportEmail(env, { id, received, r2Key, install, app, device, message, email, diagnostics });
	return json({ id }, 201);
}

export function reportKey(id: string): string {
	return `reports/${id}.json`;
}

export function newReportId(): string {
	const limit = 256 - (256 % REPORT_ID_ALPHABET.length);
	let id = "";
	while (id.length < 6) {
		for (const byte of crypto.getRandomValues(new Uint8Array(8))) {
			if (byte < limit && id.length < 6) id += REPORT_ID_ALPHABET[byte % REPORT_ID_ALPHABET.length];
		}
	}
	return `HS-${id}`;
}

/** Inserts with fresh ids until one is unused, so a collision never overwrites another report. */
async function insertWithUniqueId(env: Env, statement: (id: string) => D1PreparedStatement): Promise<string> {
	for (let attempt = 1; ; attempt++) {
		const id = newReportId();
		try {
			await statement(id).run();
			return id;
		} catch (error) {
			if (attempt >= ID_ATTEMPTS || !String(error).includes("UNIQUE")) throw error;
		}
	}
}

function parseMessage(value: unknown): string {
	if (typeof value !== "string" || value.trim() === "") badRequest("message: required");
	if (value.length > MAX_MESSAGE && characterCount(value) > MAX_MESSAGE) {
		badRequest(`message: longer than ${MAX_MESSAGE} characters`);
	}
	return value;
}

/** Counts user-perceived characters, like Swift's `String.count`. */
function characterCount(text: string): number {
	let count = 0;
	for (const _ of new Intl.Segmenter("en", { granularity: "grapheme" }).segment(text)) count++;
	return count;
}

function parseEmail(value: unknown): string | null {
	if (value === undefined || value === null) return null;
	if (typeof value !== "string") badRequest("email: must be a string");
	const email = value.trim();
	if (email === "") return null;
	if (email.length > MAX_EMAIL || CONTROL_CHARACTERS.test(email) || !EMAIL_PATTERN.test(email)) {
		badRequest("email: not a valid email address");
	}
	return email;
}

async function sendReportEmail(env: Env, report: Report): Promise<void> {
	const to = env.REPORT_TO?.trim();
	if (!to || !env.MAIL) {
		console.warn(`report ${report.id}: email skipped, REPORT_TO or MAIL is not configured`);
		return;
	}
	try {
		await env.MAIL.send({
			from: REPORT_FROM,
			to,
			...(report.email && REPLY_TO_PATTERN.test(report.email) ? { replyTo: report.email } : {}),
			subject: reportSubject(report.id, report.message),
			text: reportText(report),
		});
	} catch (error) {
		const code = isObject(error) && typeof error.code === "string" ? `${error.code}: ` : "";
		console.error(`report ${report.id}: email failed: ${code}${error instanceof Error ? error.message : String(error)}`);
	}
}

export function reportSubject(id: string, message: string): string {
	const line = message.replace(/[\s\u0000-\u001f\u007f]+/g, " ").trim();
	return `[Homespun ${id}] ${Array.from(line).slice(0, 60).join("")}`;
}

function reportText(report: Report): string {
	const { app, device } = report;
	const lines = [
		report.message,
		"",
		"----------------------------------------",
		`Report:   ${report.id}`,
		`Received: ${report.received}`,
		`Email:    ${report.email ?? "(none given)"}`,
		`Install:  ${report.install ?? "(none)"}`,
		`App:      ${app.version} (${app.build}), ${app.channel}`,
		`Device:   ${device.model} (${device.family}), OS ${device.os}`,
		`Stored:   R2 ${report.r2Key}`,
		`          wrangler r2 object get homespun-telemetry/${report.r2Key} --remote --file ${report.id}.json`,
		"",
	];
	if (report.diagnostics === null) {
		lines.push("Diagnostics: none attached");
	} else {
		const pretty = JSON.stringify(report.diagnostics, null, 2);
		if (pretty.length <= EMAIL_DIAGNOSTICS_LIMIT) {
			lines.push("Diagnostics:", pretty);
		} else {
			let shown = pretty.slice(0, EMAIL_DIAGNOSTICS_LIMIT);
			if (/[\ud800-\udbff]$/.test(shown)) shown = shown.slice(0, -1);
			lines.push(
				`Diagnostics (first ${EMAIL_DIAGNOSTICS_LIMIT} of ${pretty.length} characters; the full JSON is in R2):`,
				shown,
				`[truncated, see ${report.r2Key}]`,
			);
		}
	}
	return `${lines.join("\n")}\n`;
}
