// SPDX-License-Identifier: AGPL-3.0-only

import { describe, expect, it } from "vitest";
import diagnosticPayload from "./fixtures/diagnostic-payload.json";
import metricPayload from "./fixtures/metric-payload.json";
import { APP, DEVICE, fakeMail, newInstall, objectText, post, rows, send, sendWith } from "./helpers";

/** Uploads one of everything for `install` and returns the R2 keys it created. */
async function seed(install: string): Promise<string[]> {
	const events = [
		{ name: "app.launch", time: "2026-11-15T21:40:00Z", props: { cold: true } },
		{ name: "analytics.optin", time: "2026-11-15T21:40:01Z", props: {} },
	];
	expect((await post("/v1/events", { install, app: APP, device: DEVICE, events })).status).toBe(202);
	expect((await post("/v1/metrics", { install, app: APP, device: DEVICE, payload: metricPayload })).status).toBe(202);
	expect((await post("/v1/diagnostics", { install, app: APP, device: DEVICE, payload: diagnosticPayload })).status).toBe(202);
	const report = { install, app: APP, device: DEVICE, message: "Something broke" };
	expect((await sendWith({ MAIL: fakeMail().binding }, "POST", "/v1/reports", report)).status).toBe(201);
	return keysOf(install);
}

async function keysOf(install: string): Promise<string[]> {
	const found = await rows<{ r2_key: string }>(
		"SELECT r2_key FROM payloads WHERE install = ?1 UNION ALL SELECT r2_key FROM reports WHERE install = ?1",
		install,
	);
	return found.map((row) => row.r2_key);
}

async function counts(install: string) {
	const [row] = await rows<{ events: number; payloads: number; reports: number }>(
		`SELECT (SELECT count(*) FROM events WHERE install = ?1) AS events,
			(SELECT count(*) FROM payloads WHERE install = ?1) AS payloads,
			(SELECT count(*) FROM reports WHERE install = ?1) AS reports`,
		install,
	);
	return row;
}

describe("DELETE /v1/installs/<install>", () => {
	it("deletes everything for the install and nothing else", async () => {
		const [gone, kept] = [newInstall(), newInstall()];
		const goneKeys = await seed(gone);
		const keptKeys = await seed(kept);
		expect(goneKeys).toHaveLength(3);
		expect(await counts(gone)).toEqual({ events: 2, payloads: 2, reports: 1 });

		const response = await send("DELETE", `/v1/installs/${gone}`);
		expect(response.status).toBe(204);
		expect(await response.text()).toBe("");

		expect(await counts(gone)).toEqual({ events: 0, payloads: 0, reports: 0 });
		for (const key of goneKeys) expect(await objectText(key), key).toBeNull();

		expect(await counts(kept)).toEqual({ events: 2, payloads: 2, reports: 1 });
		for (const key of keptKeys) expect(await objectText(key), key).not.toBeNull();
	});

	it("returns 204 when nothing exists for the install", async () => {
		expect((await send("DELETE", `/v1/installs/${newInstall()}`)).status).toBe(204);
	});

	it("rejects an invalid install id", async () => {
		for (const id of ["not-a-uuid", "8A7E7C1C-6B7A-4A55-9D3E-0C1B2A3D4E5F", "%27%20OR%201%3D1"]) {
			const response = await send("DELETE", `/v1/installs/${id}`);
			expect(response.status, id).toBe(400);
			expect(await response.json()).toEqual({ error: "install: must be a lowercase UUID" });
		}
	});
});
