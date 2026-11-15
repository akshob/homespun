// SPDX-License-Identifier: AGPL-3.0-only

import { describe, expect, it } from "vitest";
import { APP, DEVICE, makeRequest, newInstall, post, randomIp, send, sendWith } from "./helpers";
import { exports } from "cloudflare:workers";

const event = { name: "app.launch", time: "2026-11-15T21:40:00Z", props: { cold: true } };
const batch = () => ({ install: newInstall(), app: APP, device: DEVICE, events: [event] });

describe("routing", () => {
	it("answers health without a key", async () => {
		const response = await send("GET", "/v1/health", undefined, { key: null });
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ ok: true });
	});

	it("rejects unknown paths with 404", async () => {
		for (const path of ["/", "/v1", "/v1/event", "/v1/events/", "/v2/events", "/v1/installs/"]) {
			const response = await send("POST", path, batch());
			expect(response.status, path).toBe(404);
			expect(await response.json()).toEqual({ error: "not found" });
		}
	});

	it("rejects wrong methods with 405 and Allow", async () => {
		const cases: [string, string, string][] = [
			["GET", "/v1/events", "POST"],
			["PUT", "/v1/reports", "POST"],
			["POST", "/v1/health", "GET"],
			["GET", `/v1/installs/${newInstall()}`, "DELETE"],
		];
		for (const [method, path, allow] of cases) {
			const response = await send(method, path);
			expect(response.status, `${method} ${path}`).toBe(405);
			expect(response.headers.get("Allow")).toBe(allow);
		}
	});
});

describe("key", () => {
	it("rejects a missing key with 401", async () => {
		const response = await post("/v1/events", batch(), { key: null });
		expect(response.status).toBe(401);
		expect(await response.json()).toEqual({ error: "missing or invalid key" });
	});

	it("rejects a wrong key with 401 on every keyed endpoint", async () => {
		for (const path of ["/v1/events", "/v1/metrics", "/v1/diagnostics", "/v1/reports"]) {
			expect((await post(path, {}, { key: "homespun-app-v2" })).status, path).toBe(401);
		}
		expect((await send("DELETE", `/v1/installs/${newInstall()}`, undefined, { key: "nope" })).status).toBe(401);
	});
});

describe("body", () => {
	it("rejects non-JSON content types with 415", async () => {
		for (const contentType of [null, "text/plain", "application/x-www-form-urlencoded", "application/jsonp"]) {
			const response = await post("/v1/events", batch(), { contentType });
			expect(response.status, String(contentType)).toBe(415);
		}
		expect((await post("/v1/events", batch(), { contentType: "application/json; charset=utf-8" })).status).toBe(202);
	});

	it("rejects bodies over the limit with 413", async () => {
		const big = { ...batch(), padding: "x".repeat(64 * 1024) };
		expect((await post("/v1/events", big)).status).toBe(413);
		const metrics = { install: newInstall(), app: APP, device: DEVICE, payload: { blob: "x".repeat(512 * 1024) } };
		expect((await post("/v1/metrics", metrics)).status).toBe(413);
		const diagnostics = { ...metrics, payload: { blob: "x".repeat(1024 * 1024) } };
		expect((await post("/v1/diagnostics", diagnostics)).status).toBe(413);
		const report = { install: null, app: APP, device: DEVICE, message: "hi", diagnostics: { blob: "x".repeat(2 * 1024 * 1024) } };
		expect((await post("/v1/reports", report)).status).toBe(413);
	});

	it("rejects an oversized body without Content-Length while streaming", async () => {
		const chunk = new TextEncoder().encode(`{"padding":"${"x".repeat(16 * 1024)}`);
		let sent = 0;
		const stream = new ReadableStream<Uint8Array>({
			pull(controller) {
				if (sent++ < 8) controller.enqueue(chunk);
				else controller.close();
			},
		});
		const request = makeRequest("POST", "/v1/events", undefined, { body: stream, contentType: "application/json" });
		const response = await exports.default.fetch(request);
		expect(response.status).toBe(413);
	});

	it("rejects malformed JSON and non-object bodies with 400", async () => {
		for (const body of ["", "{", "[]", "null", "42", '"text"']) {
			const response = await post("/v1/events", undefined, { body });
			expect(response.status, body).toBe(400);
			expect((await response.json<{ error: string }>()).error).toMatch(/body/);
		}
	});
});

describe("rate limits", () => {
	const deny = { limit: async () => ({ success: false }) };
	const allow = { limit: async () => ({ success: true }) };

	it("returns 429 when the general limiter refuses", async () => {
		const response = await sendWith({ LIMITER: deny }, "POST", "/v1/events", batch());
		expect(response.status).toBe(429);
		expect(response.headers.get("Retry-After")).toBe("60");
		expect(await response.json()).toEqual({ error: "too many requests" });
		expect((await sendWith({ LIMITER: deny }, "DELETE", `/v1/installs/${newInstall()}`)).status).toBe(429);
	});

	it("applies the report limiter only to reports", async () => {
		const report = { install: null, app: APP, device: DEVICE, message: "hello" };
		expect((await sendWith({ LIMITER: allow, REPORT_LIMITER: deny }, "POST", "/v1/reports", report)).status).toBe(429);
		expect((await sendWith({ LIMITER: allow, REPORT_LIMITER: deny }, "POST", "/v1/events", batch())).status).toBe(202);
	});

	it("enforces 60 requests a minute per IP with the real binding", async () => {
		await awayFromMinuteBoundary();
		const ip = randomIp();
		const statuses: number[] = [];
		for (let i = 0; i < 61; i++) {
			statuses.push((await send("DELETE", `/v1/installs/${newInstall()}`, undefined, { ip })).status);
		}
		expect(statuses.slice(0, 60).every((status) => status === 204)).toBe(true);
		expect(statuses[60]).toBe(429);
		// Another client is unaffected.
		expect((await send("DELETE", `/v1/installs/${newInstall()}`)).status).toBe(204);
	}, 30_000);

	it("enforces 2 reports a minute per IP with the real binding", async () => {
		await awayFromMinuteBoundary();
		const ip = randomIp();
		const report = { install: null, app: APP, device: DEVICE, message: "rate limit test" };
		const statuses = [];
		for (let i = 0; i < 3; i++) statuses.push((await post("/v1/reports", report, { ip })).status);
		expect(statuses).toEqual([201, 201, 429]);
	}, 30_000);
});

/** Local limiter windows are aligned to wall-clock minutes; avoid straddling one. */
async function awayFromMinuteBoundary(): Promise<void> {
	const intoMinute = Date.now() % 60_000;
	if (intoMinute > 50_000) await new Promise((resolve) => setTimeout(resolve, 60_500 - intoMinute));
}
