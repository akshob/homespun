// SPDX-License-Identifier: AGPL-3.0-only

import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { flagKeys, limitsFrom, usageKeys, utcDay } from "../src/budget";
import { runRetention } from "../src/retention";
import metricPayload from "./fixtures/metric-payload.json";
import { APP, DEVICE, fakeMail, newInstall, objectText, rows, sendWith } from "./helpers";

const DAY = 24 * 60 * 60 * 1000;
const today = () => usageKeys(new Date());
const flags = () => flagKeys(new Date());
const daysAgo = (days: number) => new Date(Date.now() - days * DAY);

async function setUsage(values: Record<string, number>): Promise<void> {
	await env.DB.batch(
		Object.entries(values).map(([key, value]) =>
			env.DB.prepare("INSERT INTO usage (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(key, value),
		),
	);
}

async function usage(key: string): Promise<number | undefined> {
	return (await rows<{ value: number }>("SELECT value FROM usage WHERE key = ?1", key))[0]?.value;
}

const bytesOf = (body: unknown) => new TextEncoder().encode(JSON.stringify(body)).byteLength;
const metrics = (install = newInstall()) => ({ install, app: APP, device: DEVICE, payload: metricPayload });
const report = (changes: Record<string, unknown> = {}) => ({
	install: newInstall(),
	app: APP,
	device: DEVICE,
	message: "Backup stopped",
	diagnostics: { lastRun: { items: 3 } },
	...changes,
});
const batch = (count: number, install = newInstall()) => ({
	install,
	app: APP,
	device: DEVICE,
	events: Array.from({ length: count }, () => ({ name: "app.launch", time: "2026-11-15T21:40:00Z", props: { cold: true } })),
});

/** Runs the daily job (what `scheduled` calls) with some bindings or caps replaced. */
async function cron(overrides: Record<string, unknown> = {}, mail = fakeMail()) {
	const result = await runRetention({ ...env, MAIL: mail.binding, ...overrides } as unknown as Env, new Date());
	return { result, mail };
}

beforeEach(async () => {
	await env.DB.batch(["usage", "events", "payloads", "reports"].map((table) => env.DB.prepare(`DELETE FROM ${table}`)));
});

afterEach(() => {
	vi.restoreAllMocks();
});

describe("limits", () => {
	it("parses string vars and falls back to defaults", () => {
		const defaults = limitsFrom({} as Env);
		expect(defaults).toEqual({
			r2MaxBytes: 8_000_000_000,
			r2MaxPutsMonth: 800_000,
			r2MaxPutsDay: 25_000,
			r2MaxBytesDay: 250_000_000,
			eventsMaxDay: 20_000,
			reportEmailsMaxDay: 50,
			d1MaxWritesDay: 80_000,
		});
		const parsed = limitsFrom({ R2_MAX_BYTES: " 123 ", EVENTS_MAX_DAY: 7, R2_MAX_PUTS_DAY: "0" } as unknown as Env);
		expect(parsed).toMatchObject({ r2MaxBytes: 123, eventsMaxDay: 7, r2MaxPutsDay: 0 });
		for (const bad of ["-5", "1e3", "12.5", "lots", "", "99999999999999999999", null]) {
			expect(limitsFrom({ R2_MAX_BYTES: bad } as unknown as Env).r2MaxBytes, String(bad)).toBe(8_000_000_000);
		}
	});
});

describe("metrics and diagnostics", () => {
	it("count their bytes, puts and D1 writes", async () => {
		const body = metrics();
		const size = bytesOf(body);
		const response = await sendWith({}, "POST", "/v1/metrics", body);
		expect(await response.json()).toEqual({ accepted: 1 });
		const [row] = await rows<{ size: number }>("SELECT size FROM payloads WHERE install = ?1", body.install);
		expect(row.size).toBe(size);
		const keys = today();
		expect(await usage(keys.storedBytes)).toBe(size);
		expect(await usage(keys.monthPuts)).toBe(1);
		expect(await usage(keys.dayPuts)).toBe(1);
		expect(await usage(keys.dayBytes)).toBe(size);
		// The row and its 3 indexes, plus 5 counters.
		expect(await usage(keys.dayWrites)).toBe(9);
	});

	it.each([
		["stored bytes", "storedBytes", "R2_MAX_BYTES", 1_000_000],
		["month puts", "monthPuts", "R2_MAX_PUTS_MONTH", 100],
		["day puts", "dayPuts", "R2_MAX_PUTS_DAY", 100],
		["day bytes", "dayBytes", "R2_MAX_BYTES_DAY", 1_000_000],
		["D1 writes", "dayWrites", "D1_MAX_WRITES_DAY", 1000],
	] as const)("are refused past 90%% of the %s cap", async (_, counter, variable, cap) => {
		const body = metrics();
		const delta = { storedBytes: bytesOf(body), monthPuts: 1, dayPuts: 1, dayBytes: bytesOf(body), dayWrites: 9 }[counter];
		const caps = { [variable]: String(cap) };
		const key = today()[counter];

		await setUsage({ [key]: (cap * 9) / 10 - delta });
		expect(await (await sendWith(caps, "POST", "/v1/metrics", body)).json()).toEqual({ accepted: 1 });

		const before = await usage(key);
		const refused = await sendWith(caps, "POST", "/v1/diagnostics", { ...body, install: newInstall() });
		expect(refused.status).toBe(202);
		expect(await refused.json()).toEqual({ accepted: 0, reason: "budget" });
		expect(await rows("SELECT id FROM payloads WHERE kind = 'diagnostics'")).toHaveLength(0);
		expect(await usage(key)).toBe(before);
		expect(await usage(counter === "dayWrites" ? flags().d1 : flags().r2)).toBe(1);
	});

	it("are limited per install and UTC day", async () => {
		const install = newInstall();
		await env.DB.prepare("INSERT INTO payloads (id, install, kind, received, r2_key) VALUES ('old', ?1, 'metrics', ?2, 'x')")
			.bind(install, daysAgo(1).toISOString())
			.run();
		for (let i = 0; i < 3; i++) {
			expect(await (await sendWith({}, "POST", "/v1/metrics", metrics(install))).json()).toEqual({ accepted: 1 });
		}
		const limited = await sendWith({}, "POST", "/v1/metrics", metrics(install));
		expect(limited.status).toBe(202);
		expect(await limited.json()).toEqual({ accepted: 0, reason: "limit" });
		expect(await rows("SELECT id FROM payloads WHERE install = ?1", install)).toHaveLength(4);
		expect(await usage(today().dayPuts)).toBe(3);

		// Other kinds and installs are counted separately.
		expect(await (await sendWith({}, "POST", "/v1/metrics", metrics())).json()).toEqual({ accepted: 1 });
		for (let i = 0; i < 20; i++) {
			const response = await sendWith({}, "POST", "/v1/diagnostics", { ...metrics(install), payload: {} });
			expect(await response.json(), `diagnostics ${i + 1}`).toEqual({ accepted: 1 });
		}
		const diagnostics = await sendWith({}, "POST", "/v1/diagnostics", { ...metrics(install), payload: {} });
		expect(await diagnostics.json()).toEqual({ accepted: 0, reason: "limit" });
	});
});

describe("events", () => {
	it("count events and D1 writes", async () => {
		expect(await (await sendWith({}, "POST", "/v1/events", batch(3))).json()).toEqual({ accepted: 3 });
		expect(await usage(today().dayEvents)).toBe(3);
		expect(await usage(today().dayWrites)).toBe(3 * 4 + 2);
	});

	it("answer 503 busy past the daily event cap", async () => {
		const caps = { EVENTS_MAX_DAY: "10" };
		await setUsage({ [today().dayEvents]: 8 });
		const install = newInstall();
		const busy = await sendWith(caps, "POST", "/v1/events", batch(3, install));
		expect(busy.status).toBe(503);
		expect(await busy.json()).toEqual({ error: "busy" });
		const retryAfter = Number(busy.headers.get("Retry-After"));
		expect(retryAfter).toBeGreaterThan(0);
		expect(retryAfter).toBeLessThanOrEqual(86_400);
		expect(await rows("SELECT id FROM events WHERE install = ?1", install)).toHaveLength(0);
		expect(await usage(flags().events)).toBe(1);

		expect((await sendWith(caps, "POST", "/v1/events", batch(2, install))).status).toBe(202);
		expect(await usage(today().dayEvents)).toBe(10);
		expect((await sendWith(caps, "POST", "/v1/events", batch(1, install))).status).toBe(503);
	});

	it("answer 503 busy past 90% of the D1 write cap", async () => {
		const caps = { D1_MAX_WRITES_DAY: "1000" };
		await setUsage({ [today().dayWrites]: 900 - 6 });
		expect((await sendWith(caps, "POST", "/v1/events", batch(1))).status).toBe(202);
		expect(await usage(today().dayWrites)).toBe(900);
		expect((await sendWith(caps, "POST", "/v1/events", batch(1))).status).toBe(503);
		expect(await usage(flags().d1)).toBe(1);
		expect(await usage(flags().events)).toBeUndefined();
	});
});

describe("reports", () => {
	it("keep using R2 between 90% and 100% of a cap", async () => {
		const caps = { R2_MAX_PUTS_DAY: "100" };
		await setUsage({ [today().dayPuts]: 99 });
		const mail = fakeMail();
		const body = report();
		const response = await sendWith({ ...caps, MAIL: mail.binding }, "POST", "/v1/reports", body);
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		const [row] = await rows<{ r2_key: string; size: number }>("SELECT r2_key, size FROM reports WHERE id = ?1", id);
		expect(row).toEqual({ r2_key: `reports/${id}.json`, size: bytesOf(body) });
		expect(await objectText(`reports/${id}.json`)).not.toBeNull();
		expect(await usage(today().dayPuts)).toBe(100);
		expect(await usage(today().storedBytes)).toBe(bytesOf(body));
		expect(await usage(today().dayEmails)).toBe(1);
	});

	it("are kept in D1 only and still emailed past 100% of an R2 cap", async () => {
		vi.spyOn(console, "warn").mockImplementation(() => {});
		const caps = { R2_MAX_BYTES: "1000000" };
		await setUsage({ [today().storedBytes]: 1_000_000 - 10 });
		const mail = fakeMail();
		const diagnostics = { log: "x".repeat(30_000) };
		const response = await sendWith({ ...caps, MAIL: mail.binding }, "POST", "/v1/reports", report({ diagnostics }));
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		const [row] = await rows<{ r2_key: string; size: number; message: string }>(
			"SELECT r2_key, size, message FROM reports WHERE id = ?1",
			id,
		);
		expect(row).toEqual({ r2_key: "", size: 0, message: "Backup stopped" });
		expect(await objectText(`reports/${id}.json`)).toBeNull();
		expect(await usage(today().storedBytes)).toBe(1_000_000 - 10);
		expect(await usage(today().dayPuts)).toBeUndefined();
		expect(await usage(flags().r2)).toBe(1);

		expect(mail.sent).toHaveLength(1);
		expect(mail.sent[0].text).toContain("Stored:   D1 only, without the diagnostics (the R2 budget is used up)");
		expect(mail.sent[0].text).toContain("[truncated; the rest was not kept]");
		expect(mail.sent[0].text).not.toContain("wrangler r2 object get");
	});

	it("are kept in D1 only when the R2 write fails", async () => {
		vi.spyOn(console, "error").mockImplementation(() => {});
		const mail = fakeMail();
		const bucket = {
			put: async () => {
				throw new Error("R2 unavailable");
			},
		};
		const response = await sendWith({ BUCKET: bucket, MAIL: mail.binding }, "POST", "/v1/reports", report());
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		expect(await rows("SELECT r2_key, size FROM reports WHERE id = ?1", id)).toEqual([{ r2_key: "", size: 0 }]);
		expect(await usage(today().storedBytes)).toBeUndefined();
		expect(mail.sent[0].text).toContain("D1 only, without the diagnostics (the R2 write failed)");
	});

	it("are stored but not emailed past the daily email cap", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		const caps = { REPORT_EMAILS_MAX_DAY: "2" };
		await setUsage({ [today().dayEmails]: 1 });
		const mail = fakeMail({ fail: true });
		vi.spyOn(console, "error").mockImplementation(() => {});
		expect((await sendWith({ ...caps, MAIL: mail.binding }, "POST", "/v1/reports", report())).status).toBe(201);
		// A failed send still counts.
		expect(await usage(today().dayEmails)).toBe(2);

		const response = await sendWith({ ...caps, MAIL: mail.binding }, "POST", "/v1/reports", report());
		expect(response.status).toBe(201);
		const { id } = await response.json<{ id: string }>();
		expect(mail.sent).toHaveLength(1);
		expect(await rows("SELECT id FROM reports WHERE id = ?1", id)).toHaveLength(1);
		expect(await objectText(`reports/${id}.json`)).not.toBeNull();
		expect(await usage(today().dayEmails)).toBe(2);
		expect(warn).toHaveBeenCalledWith(expect.stringContaining(`report ${id}: not emailed`));
	});

	it("may use the D1 write budget up to 100%, then answer 503", async () => {
		const caps = { D1_MAX_WRITES_DAY: "1000" };
		// Worst case for a report: the row (4), a fallback update (1) and 6 counters.
		await setUsage({ [today().dayWrites]: 1000 - 11 });
		expect((await sendWith({ ...caps, MAIL: fakeMail().binding }, "POST", "/v1/reports", report())).status).toBe(201);
		expect((await sendWith(caps, "POST", "/v1/events", batch(1))).status).toBe(503);

		await setUsage({ [today().dayWrites]: 1000 - 10 });
		const busy = await sendWith({ ...caps, MAIL: fakeMail().binding }, "POST", "/v1/reports", report());
		expect(busy.status).toBe(503);
		expect(await busy.json()).toEqual({ error: "busy" });
	});
});

describe("deletes", () => {
	it("release the deleted bytes, never below 0", async () => {
		const [gone, kept] = [newInstall(), newInstall()];
		const mail = fakeMail();
		for (const install of [gone, kept]) {
			expect((await sendWith({}, "POST", "/v1/metrics", metrics(install))).status).toBe(202);
			expect((await sendWith({ MAIL: mail.binding }, "POST", "/v1/reports", report({ install }))).status).toBe(201);
		}
		const total = await usage(today().storedBytes);
		const [{ bytes }] = await rows<{ bytes: number }>(
			"SELECT (SELECT sum(size) FROM payloads WHERE install = ?1) + (SELECT sum(size) FROM reports WHERE install = ?1) AS bytes",
			gone,
		);
		const writes = (await usage(today().dayWrites))!;

		expect((await sendWith({}, "DELETE", `/v1/installs/${gone}`)).status).toBe(204);
		expect(await usage(today().storedBytes)).toBe(total! - bytes);
		// 2 rows with 3 indexes each, r2.bytes, and the writes counter.
		expect(await usage(today().dayWrites)).toBe(writes + 2 * 4 + 2);

		await setUsage({ [today().storedBytes]: 5 });
		expect((await sendWith({}, "DELETE", `/v1/installs/${kept}`)).status).toBe(204);
		expect(await usage(today().storedBytes)).toBe(0);
	});

	it("skip reports without an R2 object", async () => {
		const install = newInstall();
		await env.DB.prepare("INSERT INTO reports (id, install, received, message, r2_key, size) VALUES ('HS-D1ONLY', ?1, ?2, 'hi', '', 0)")
			.bind(install, new Date().toISOString())
			.run();
		expect((await sendWith({}, "DELETE", `/v1/installs/${install}`)).status).toBe(204);
		expect(await rows("SELECT id FROM reports WHERE install = ?1", install)).toHaveLength(0);
	});
});

describe("scheduled", () => {
	async function addPayload(kind: string, ageDays: number, size: number): Promise<string> {
		const id = crypto.randomUUID();
		const key = `${kind}/test/${id}.json`;
		await env.BUCKET.put(key, "x".repeat(size));
		await env.DB.prepare("INSERT INTO payloads (id, install, kind, received, r2_key, size) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
			.bind(id, newInstall(), kind, daysAgo(ageDays).toISOString(), key, size)
			.run();
		return key;
	}

	it("keeps metrics 90 days and diagnostics 365 days", async () => {
		const oldMetrics = await addPayload("metrics", 91, 10);
		const newMetrics = await addPayload("metrics", 89, 20);
		const oldDiagnostics = await addPayload("diagnostics", 366, 30);
		const newDiagnostics = await addPayload("diagnostics", 364, 40);
		const { result } = await cron();
		expect(result).toMatchObject({ metrics: 1, diagnostics: 1, storedBytes: 60 });
		expect(await objectText(oldMetrics)).toBeNull();
		expect(await objectText(oldDiagnostics)).toBeNull();
		expect(await objectText(newMetrics)).not.toBeNull();
		expect(await objectText(newDiagnostics)).not.toBeNull();
		expect(await rows("SELECT size FROM payloads ORDER BY size")).toEqual([{ size: 20 }, { size: 40 }]);
	});

	it("reconciles r2.bytes with the tables and counts its D1 writes", async () => {
		await addPayload("metrics", 1, 100);
		await env.DB.prepare("INSERT INTO reports (id, install, received, message, r2_key, size) VALUES ('HS-AAAAAA', NULL, ?1, 'hi', 'reports/HS-AAAAAA.json', 50)")
			.bind(new Date().toISOString())
			.run();
		await setUsage({ [today().storedBytes]: 123_456, [today().dayWrites]: 10 });
		await cron();
		expect(await usage("r2.bytes")).toBe(150);
		expect(await usage(today().dayWrites)).toBeGreaterThan(10);
	});

	it("deletes old usage counters", async () => {
		const day = (days: number) => utcDay(daysAgo(days));
		const now = new Date();
		const month = (back: number) => new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - back, 1)).toISOString().slice(0, 7);
		await setUsage({
			[`events.${day(41)}`]: 1,
			[`d1.full.${day(45)}`]: 1,
			[`alert.daily.${day(50)}`]: 1,
			[`events.${day(39)}`]: 1,
			[`r2.puts.${month(14)}`]: 1,
			[`alert.storage.50.${month(14)}`]: 1,
			[`r2.puts.${month(13)}`]: 1,
			[`r2.puts.${month(0)}`]: 1,
		});
		await cron();
		const keys = (await rows<{ key: string }>("SELECT key FROM usage")).map((row) => row.key);
		expect(keys).toEqual(expect.arrayContaining([`events.${day(39)}`, `r2.puts.${month(13)}`, `r2.puts.${month(0)}`, "r2.bytes"]));
		for (const gone of [`events.${day(41)}`, `d1.full.${day(45)}`, `alert.daily.${day(50)}`, `r2.puts.${month(14)}`, `alert.storage.50.${month(14)}`]) {
			expect(keys).not.toContain(gone);
		}
	});

	it("limits one run's deletes to a quarter of the D1 write budget", async () => {
		const old = daysAgo(401).toISOString();
		await env.DB.batch(
			Array.from({ length: 300 }, (_, i) =>
				env.DB.prepare("INSERT INTO events (install, time, received, name, props) VALUES (?1, ?2, ?2, 'app.launch', '{}')").bind(`i${i}`, old),
			),
		);
		const { result } = await cron({ D1_MAX_WRITES_DAY: "800" });
		expect(result.events).toBe(50);
		expect(await rows("SELECT id FROM events")).toHaveLength(250);
	});
});

describe("alerts", () => {
	const caps = { R2_MAX_BYTES: "1000000", R2_MAX_PUTS_MONTH: "100" };

	it("email once per storage threshold and month", async () => {
		await addStored(760_000);
		const first = await cron(caps);
		expect(first.mail.sent.map((email) => email.subject)).toEqual(["[Homespun telemetry] R2 storage at 76% of its budget"]);
		const [email] = first.mail.sent;
		expect(email.from).toEqual({ email: "reports@homespun.photos", name: "Homespun Telemetry" });
		expect(email.to).toBe("owner@example.com");
		expect(email.text).toContain("R2 stored now");
		expect(email.text).toContain("760.0 kB of 1.0 MB (76%)");
		expect(email.text).toContain("Report emails on");
		expect(email.text).toContain("SELECT * FROM usage ORDER BY key");
		const month = utcDay(new Date()).slice(0, 7);
		expect(await usage(`alert.storage.50.${month}`)).toBe(1);
		expect(await usage(`alert.storage.75.${month}`)).toBe(1);
		expect(await usage(today().dayEmails)).toBeUndefined();

		expect((await cron(caps)).mail.sent).toHaveLength(0);
		await addStored(150_000);
		expect((await cron(caps)).mail.sent.map((sent) => sent.subject)).toEqual(["[Homespun telemetry] R2 storage at 91% of its budget"]);
		expect((await cron(caps)).mail.sent).toHaveLength(0);
	});

	it("email when this month's R2 writes cross a threshold", async () => {
		await setUsage({ [usageKeys(daysAgo(1)).monthPuts]: 52 });
		const { mail } = await cron(caps);
		expect(mail.sent.map((email) => email.subject)).toEqual(["[Homespun telemetry] R2 writes at 52% of this month's budget"]);
		expect((await cron(caps)).mail.sent).toHaveLength(0);
	});

	it("retry an alert whose email failed", async () => {
		vi.spyOn(console, "error").mockImplementation(() => {});
		await addStored(500_000);
		expect((await cron(caps, fakeMail({ fail: true }))).result.alerts).toEqual([]);
		expect((await cron(caps)).mail.sent).toHaveLength(1);
	});

	it("email once a day when yesterday hit a daily cap", async () => {
		const yesterday = utcDay(daysAgo(1));
		await setUsage({ [`events.full.${yesterday}`]: 1, [`emails.${yesterday}`]: 50 });
		const { mail } = await cron();
		expect(mail.sent).toHaveLength(1);
		expect(mail.sent[0].subject).toBe(`[Homespun telemetry] Daily caps reached on ${yesterday}`);
		expect(mail.sent[0].text).toContain("- events (batches were refused with 503");
		expect(mail.sent[0].text).toContain("- report emails (later reports were stored but not emailed)");
		expect((await cron()).mail.sent).toHaveLength(0);
	});

	it("stay quiet below the thresholds", async () => {
		await addStored(490_000);
		await setUsage({ [usageKeys(daysAgo(1)).monthPuts]: 49, [`emails.${utcDay(daysAgo(1))}`]: 49 });
		expect((await cron(caps)).mail.sent).toHaveLength(0);
	});

	async function addStored(size: number): Promise<void> {
		await env.DB.prepare("INSERT INTO payloads (id, install, kind, received, r2_key, size) VALUES (?1, ?2, 'diagnostics', ?3, 'k', ?4)")
			.bind(crypto.randomUUID(), newInstall(), new Date().toISOString(), size)
			.run();
	}
});
