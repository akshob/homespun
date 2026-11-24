// SPDX-License-Identifier: AGPL-3.0-only

import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { Budget, r2Put, withWrites } from "../src/budget";
import { runRetention } from "../src/retention";
import { OBJECT_WRITE_WRITES, reserveWrite } from "../src/writes";
import diagnosticPayload from "./fixtures/diagnostic-payload.json";
import metricPayload from "./fixtures/metric-payload.json";
import { APP, DEVICE, barrier, fakeMail, interceptDatabase, newInstall, objectText, post, rows, send, sendWith } from "./helpers";

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

	it.each([
		["metrics", "before"], ["metrics", "after"], ["reports", "before"], ["reports", "after"],
	] as const)("fences %s with erasure %s its R2 PUT", async (kind, ordering) => {
		const install = newInstall();
		const gate = barrier();
		let key = "";
		const bucket = {
			async put(path: string, value: string, options: R2PutOptions) {
				key = path;
				if (ordering === "before") await gate.hold();
				const result = await env.BUCKET.put(path, value, options);
				if (ordering === "after") await gate.hold();
				return result;
			},
			delete: (keys: string | string[]) => env.BUCKET.delete(keys),
		};
		const body = { install, app: APP, device: DEVICE, ...(kind === "reports" ? { message: "Stopped" } : { payload: metricPayload }) };
		const intake = sendWith({ BUCKET: bucket, MAIL: fakeMail().binding }, "POST", `/v1/${kind}`, body);
		await gate.reached;
		// Reports have their D1 fallback row first; payloads have only their durable PUT pointer.
		expect((await counts(install)).reports).toBe(kind === "reports" ? 1 : 0);
		expect(await rows("SELECT r2_key FROM object_writes WHERE install = ?1", install)).toEqual([{ r2_key: key }]);
		expect((await send("DELETE", `/v1/installs/${install}`)).status).toBe(204);
		expect(await counts(install)).toEqual({ events: 0, payloads: 0, reports: 0 });
		gate.release();
		expect((await intake).status).toBe(410);
		expect(await objectText(key)).toBeNull();
		expect(await rows("SELECT r2_key FROM object_writes WHERE install = ?1", install)).toHaveLength(0);
	});

	it("erases a payload committed before the deletion snapshot even when its response is late", async () => {
		const install = newInstall();
		const gate = barrier();
		const db = interceptDatabase(async (sql, commit) => {
			const result = await commit();
			if (sql.some((statement) => statement.startsWith("INSERT INTO payloads"))) await gate.hold();
			return result;
		});
		const intake = sendWith({ DB: db }, "POST", "/v1/metrics", { install, app: APP, device: DEVICE, payload: metricPayload });
		await gate.reached;
		const keys = await keysOf(install);
		expect(keys).toHaveLength(1);
		expect((await send("DELETE", `/v1/installs/${install}`)).status).toBe(204);
		gate.release();
		expect((await intake).status).toBe(410);
		expect(await counts(install)).toEqual({ events: 0, payloads: 0, reports: 0 });
		expect(await objectText(keys[0])).toBeNull();
	});

	it("refuses intake while erasure is suspended after its snapshot", async () => {
		const install = newInstall();
		const keys = await seed(install);
		const gate = barrier();
		const deletion = sendWith({
			BUCKET: { async delete(paths: string[]) { await gate.hold(); return env.BUCKET.delete(paths); } },
		}, "DELETE", `/v1/installs/${install}`);
		await gate.reached;
		for (const [path, content] of [
			["events", { events: [{ name: "app.launch", time: new Date().toISOString(), props: {} }] }],
			["metrics", { payload: metricPayload }],
			["reports", { message: "Late" }],
		] as const) {
			expect((await post(`/v1/${path}`, { install, app: APP, device: DEVICE, ...content })).status).toBe(410);
		}
		gate.release();
		expect((await deletion).status).toBe(204);
		expect(await counts(install)).toEqual({ events: 0, payloads: 0, reports: 0 });
		for (const key of keys) expect(await objectText(key)).toBeNull();
	});

	it.each(["before", "after"] as const)("reconciles an interrupted writer %s PUT without forgetting its late-write pointer", async (boundary) => {
		const install = newInstall();
		const now = new Date();
		const key = `metrics/interrupted/${install}/${crypto.randomUUID()}.json`;
		const size = 10;
		const budget = await Budget.load(env, now);
		// Simulate process loss at a durable boundary: no catch/finally in the writer runs.
		await env.DB.batch([
			reserveWrite(env, key, install, size, now),
			budget.add(env.DB, withWrites(r2Put(size), OBJECT_WRITE_WRITES + 4)),
		]);
		if (boundary === "after") await env.BUCKET.put(key, "x".repeat(size));
		expect((await send("DELETE", `/v1/installs/${install}`)).status).toBe(204);
		await runRetention(env, new Date(now.getTime() + 2 * 60 * 60 * 1000));
		expect(await objectText(key)).toBeNull();
		expect(await rows("SELECT state, settled FROM object_writes WHERE r2_key = ?1", key))
			.toEqual([{ state: "cleanup", settled: 0 }]);
		// A PUT that was already issued may settle even after an erasure/sweep.
		await env.BUCKET.put(key, "x".repeat(size));
		await runRetention(env, new Date(now.getTime() + 26 * 60 * 60 * 1000));
		expect(await objectText(key)).toBeNull();
		expect(await rows("SELECT value FROM usage WHERE key = 'r2.bytes'")).toEqual([{ value: size }]);
	});

	it("keeps erasure retryable when R2 deletion fails", async () => {
		const install = newInstall();
		const keys = await seed(install);
		const failed = await sendWith({
			BUCKET: { async delete() { throw new Error("R2 unavailable"); } },
		}, "DELETE", `/v1/installs/${install}`);
		expect(failed.status).toBe(500);
		expect((await counts(install)).payloads).toBe(2);
		expect(await rows("SELECT install FROM erased_installs WHERE install = ?1", install)).toHaveLength(1);
		expect((await send("DELETE", `/v1/installs/${install}`)).status).toBe(204);
		for (const key of keys) expect(await objectText(key)).toBeNull();
	});

	it("keeps row keys retryable when D1 fails after objects were erased", async () => {
		const install = newInstall();
		const keys = await seed(install);
		const db = interceptDatabase(async (sql, commit) => {
			if (sql.some((statement) => statement.startsWith("DELETE FROM payloads"))) throw new Error("D1 deletion failed");
			return commit();
		});
		expect((await sendWith({ DB: db }, "DELETE", `/v1/installs/${install}`)).status).toBe(500);
		expect((await counts(install)).payloads).toBe(2);
		for (const key of keys) expect(await objectText(key)).toBeNull();
		expect((await send("DELETE", `/v1/installs/${install}`)).status).toBe(204);
		expect(await counts(install)).toEqual({ events: 0, payloads: 0, reports: 0 });
	});

	it.each(["events", "metrics", "reports"] as const)("fences %s admission even after its preflight passed", async (kind) => {
		const install = newInstall();
		const gate = barrier();
		const db = interceptDatabase(async (sql, commit) => {
			if (sql.some((statement) => /^INSERT INTO (events|reports|object_writes)\b/.test(statement))) await gate.hold();
			return commit();
		});
		let puts = 0;
		const bucket = {
			async put(path: string, value: string, options: R2PutOptions) {
				puts++;
				return env.BUCKET.put(path, value, options);
			},
		};
		const content = kind === "events"
			? { events: [{ name: "app.launch", time: new Date().toISOString(), props: {} }] }
			: kind === "reports" ? { message: "Passed preflight" } : { payload: metricPayload };
		const intake = sendWith({ DB: db, BUCKET: bucket }, "POST", `/v1/${kind}`, { install, app: APP, device: DEVICE, ...content });
		await gate.reached;
		expect((await send("DELETE", `/v1/installs/${install}`)).status).toBe(204);
		gate.release();
		expect((await intake).status).toBe(410);
		expect(await counts(install)).toEqual({ events: 0, payloads: 0, reports: 0 });
		expect(await rows("SELECT r2_key FROM object_writes WHERE install = ?1", install)).toHaveLength(0);
		expect(puts).toBe(0);
	});

	it("retains a failed publication/cleanup pointer for cron instead of orphaning its object", async () => {
		const install = newInstall();
		let key = "";
		const db = interceptDatabase(async (sql, commit) => {
			if (sql.some((statement) => statement.startsWith("INSERT INTO payloads"))) throw new Error("D1 publication failed");
			return commit();
		});
		const bucket = {
			async put(path: string, value: string, options: R2PutOptions) {
				key = path;
				return env.BUCKET.put(path, value, options);
			},
			async delete() { throw new Error("R2 cleanup failed"); },
		};
		const response = await sendWith({ DB: db, BUCKET: bucket }, "POST", "/v1/metrics",
			{ install, app: APP, device: DEVICE, payload: metricPayload });
		expect(response.status).toBe(500);
		expect(await objectText(key)).not.toBeNull();
		expect(await rows("SELECT state, settled FROM object_writes WHERE r2_key = ?1", key))
			.toEqual([{ state: "cleanup", settled: 1 }]);
		await runRetention(env, new Date());
		expect(await objectText(key)).toBeNull();
		expect(await rows("SELECT r2_key FROM object_writes WHERE r2_key = ?1", key)).toHaveLength(0);
	});

	it("does not expire a report's fallback row while its R2 publication is pending", async () => {
		const install = newInstall();
		const gate = barrier();
		let key = "";
		const bucket = {
			async put(path: string, value: string, options: R2PutOptions) {
				key = path;
				await gate.hold();
				return env.BUCKET.put(path, value, options);
			},
			delete: (keys: string | string[]) => env.BUCKET.delete(keys),
		};
		const intake = sendWith({ BUCKET: bucket, MAIL: fakeMail().binding }, "POST", "/v1/reports",
			{ install, app: APP, device: DEVICE, message: "Pending report" });
		await gate.reached;
		// An old receive time with a live writer (e.g. clock correction) must not let retention
		// snapshot an empty key and later remove a row whose key was just published.
		await env.DB.prepare("UPDATE reports SET received = ?1 WHERE install = ?2")
			.bind(new Date(Date.now() - 731 * 24 * 60 * 60 * 1000).toISOString(), install).run();
		await runRetention(env, new Date());
		expect((await counts(install)).reports).toBe(1);
		gate.release();
		expect((await intake).status).toBe(201);
		expect(await objectText(key)).not.toBeNull();
		await runRetention(env, new Date());
		expect((await counts(install)).reports).toBe(0);
		expect(await objectText(key)).toBeNull();
	});
});
