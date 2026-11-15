// SPDX-License-Identifier: AGPL-3.0-only

import { createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import worker from "../src/index";
import { newInstall, objectText, rows } from "./helpers";

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-11-15T03:17:00Z");
const ago = (days: number) => new Date(NOW - days * DAY).toISOString();

async function addEvent(install: string, received: string): Promise<void> {
	await env.DB.prepare("INSERT INTO events (install, time, received, name, props) VALUES (?1, ?2, ?2, 'app.launch', '{}')")
		.bind(install, received)
		.run();
}

async function addWithObject(table: "payloads" | "reports", install: string, received: string, kind = "metrics"): Promise<string> {
	const id = crypto.randomUUID();
	const key = `${table}-test/${install}/${id}.json`;
	await env.BUCKET.put(key, "{}");
	if (table === "payloads") {
		await env.DB.prepare("INSERT INTO payloads (id, install, kind, received, r2_key) VALUES (?1, ?2, ?3, ?4, ?5)")
			.bind(id, install, kind, received, key)
			.run();
	} else {
		await env.DB.prepare("INSERT INTO reports (id, install, received, message, r2_key) VALUES (?1, ?2, ?3, 'old', ?4)")
			.bind(id, install, received, key)
			.run();
	}
	return key;
}

describe("scheduled retention", () => {
	it("deletes only rows and objects past their retention", async () => {
		const install = newInstall();
		await addEvent(install, ago(401));
		await addEvent(install, ago(399));
		const oldMetrics = await addWithObject("payloads", install, ago(366), "metrics");
		const oldDiagnostics = await addWithObject("payloads", install, ago(370), "diagnostics");
		const newPayload = await addWithObject("payloads", install, ago(364), "diagnostics");
		const oldReport = await addWithObject("reports", install, ago(731));
		const newReport = await addWithObject("reports", install, ago(729));

		await worker.scheduled(createScheduledController({ scheduledTime: new Date(NOW), cron: "17 3 * * *" }), env);

		const events = await rows<{ received: string }>("SELECT received FROM events WHERE install = ?1", install);
		expect(events).toEqual([{ received: ago(399) }]);
		const payloads = await rows<{ r2_key: string }>("SELECT r2_key FROM payloads WHERE install = ?1", install);
		expect(payloads).toEqual([{ r2_key: newPayload }]);
		const reports = await rows<{ r2_key: string }>("SELECT r2_key FROM reports WHERE install = ?1", install);
		expect(reports).toEqual([{ r2_key: newReport }]);

		for (const key of [oldMetrics, oldDiagnostics, oldReport]) expect(await objectText(key), key).toBeNull();
		for (const key of [newPayload, newReport]) expect(await objectText(key), key).not.toBeNull();
	});

	it("works through more rows than one chunk", async () => {
		const install = newInstall();
		const statements = Array.from({ length: 1205 }, (_, i) =>
			env.DB.prepare("INSERT INTO payloads (id, install, kind, received, r2_key) VALUES (?1, ?2, 'metrics', ?3, ?4)").bind(
				`bulk-${install}-${i}`,
				install,
				ago(400),
				`bulk/${install}/${i}.json`,
			),
		);
		await env.DB.batch(statements);
		await env.BUCKET.put(`bulk/${install}/1204.json`, "{}");

		await worker.scheduled(createScheduledController({ scheduledTime: new Date(NOW) }), env);

		expect(await rows("SELECT id FROM payloads WHERE install = ?1", install)).toHaveLength(0);
		expect(await objectText(`bulk/${install}/1204.json`)).toBeNull();
	});
});
