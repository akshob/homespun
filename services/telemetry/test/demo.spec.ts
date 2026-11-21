// SPDX-License-Identifier: AGPL-3.0-only
import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { digest, parseManifest, sessionToken, verifyToken, type DemoManifest } from "../src/demo";
import { randomIp, sendWith } from "./helpers";

const code = "TESTTESTTESTTEST";
const secret = "local-test-signing-key-not-used-in-production";
let bindings: Partial<Record<keyof Env, unknown>>;
let media: DemoManifest;

beforeEach(async () => {
	bindings = { DEMO_CODE_SHA256: await digest(code), DEMO_SIGNING_KEY: secret };
	const bytes = "synthetic photo";
	media = { version: 1, totalBytes: bytes.length * 16, files: await Promise.all(Array.from({ length: 16 }, async (_, i) => ({
		file: `demo-test-${i}.jpg`, size: bytes.length, sha256: await digest(bytes), kind: "photo",
		width: 64, height: 48, date: "2025-01-01T10:00:00Z", category: "nature",
	}))) };
	await env.DEMO_BUCKET.put("v1/manifest.json", JSON.stringify(media));
	for (const f of media.files) await env.DEMO_BUCKET.put(`v1/${f.file}`, bytes);
});

async function grant(ip = randomIp()) {
	return sendWith(bindings, "POST", "/v1/demo/session", { code: "test-test-test-test" }, { key: null, ip });
}

describe("private reviewer demo", () => {
	it("checks the code without an app key and streams only manifest objects", async () => {
		const response = await grant();
		expect(response.status).toBe(200);
		expect(response.headers.get("Cache-Control")).toBe("no-store");
		const body = await response.json<{ manifest: DemoManifest; token: string; expiresAt: number }>();
		expect(body.manifest).toEqual(media);
		expect(body.expiresAt).toBeLessThanOrEqual(Math.floor(Date.now() / 1000) + 3600);
		const request = new Request(`https://telemetry.homespun.photos/v1/demo/files/${media.files[0].file}`,
			{ headers: { Authorization: `Bearer ${body.token}`, "CF-Connecting-IP": randomIp() } });
		const worker = (await import("../src/index")).default;
		const file = await worker.fetch(request as Parameters<typeof worker.fetch>[0], { ...env, ...bindings } as Env);
		expect(file.status).toBe(200);
		expect(await file.text()).toBe("synthetic photo");
		expect(file.headers.get("Cache-Control")).toBe("private, no-store");
	});

	it("gives the same unhelpful 403 for wrong, absent and locked-out codes", async () => {
		const ip = randomIp();
		for (let i = 0; i < 10; i++) {
			const bad = await sendWith(bindings, "POST", "/v1/demo/session", { code: "wrong" }, { ip, key: null });
			expect(bad.status).toBe(403);
			expect(await bad.json()).toEqual({ error: "forbidden" });
		}
		expect((await grant(ip)).status).toBe(403);
		expect((await grant()).status).toBe(200);
		expect((await sendWith(bindings, "POST", "/v1/demo/session", {}, { key: null })).status).toBe(403);
		expect((await sendWith(bindings, "GET", "/v1/demo/files/demo-test-0.jpg")).status).toBe(403);
		expect((await sendWith(bindings, "GET", "/v1/demo/files/manifest.json")).status).toBe(403);
	});

	it("allows reuse, including a success immediately after nine failures on a shared IP", async () => {
		const ip = randomIp();
		for (let i = 0; i < 9; i++) {
			expect((await sendWith(bindings, "POST", "/v1/demo/session", { code: "wrong" }, { ip })).status).toBe(403);
		}
		for (let i = 0; i < 3; i++) expect((await grant(ip)).status).toBe(200);
		expect((await sendWith(bindings, "POST", "/v1/demo/session", undefined, { ip, body: "not-json" })).status).toBe(403);
		expect((await grant(ip)).status).toBe(403);
	});

	it("allows the same code again after the cooldown; counters contain no raw IP", async () => {
		const ip = randomIp();
		for (let i = 0; i < 10; i++) await sendWith(bindings, "POST", "/v1/demo/session", { code: "wrong" }, { ip });
		expect((await grant(ip)).status).toBe(403);
		const counters = await env.DB.prepare("SELECT key, locked_until FROM demo_lockouts").all<{ key: string; locked_until: number }>();
		expect(counters.results.every((row) => /^[a-f0-9]{64}$/.test(row.key))).toBe(true);
		await env.DB.prepare("UPDATE demo_lockouts SET locked_until = 0, window_start = 0").run();
		expect((await grant(ip)).status).toBe(200);
	});

	it("expires sessions, rejects tampering, and invalidates them on code rotation", async () => {
		const config = { ...env, ...bindings } as Env, now = Date.now();
		const token = await sessionToken("a".repeat(64), config, now);
		expect(await verifyToken(token, config, now)).toBe("a".repeat(64));
		await expect(verifyToken(token, config, now + 3_600_000)).rejects.toMatchObject({ status: 403 });
		await expect(verifyToken(token, config, now - 1000)).rejects.toMatchObject({ status: 403 });
		await expect(verifyToken(token.slice(0, -2) + "ZZ", config, now)).rejects.toMatchObject({ status: 403 });
		await expect(verifyToken(token, { ...config, DEMO_CODE_SHA256: "b".repeat(64) }, now)).rejects.toMatchObject({ status: 403 });
	});

	it("rejects malformed, oversized and path-traversing manifests", () => {
		expect(parseManifest(media)).toEqual(media);
		for (const change of [{ file: "../private.jpg" }, { sha256: "bad" }, { size: 9 * 1024 * 1024 }, { width: 9999 }]) {
			expect(() => parseManifest({ ...media, files: [{ ...media.files[0], ...change }, ...media.files.slice(1)] })).toThrow();
		}
		expect(() => parseManifest({ ...media, totalBytes: 1 })).toThrow();
		expect(() => parseManifest({ ...media, files: [...media.files.slice(1), media.files[1]] })).toThrow();
	});

	it("stops demo requests at their daily cap and preserves the telemetry write reserve", async () => {
		const day = new Date().toISOString().slice(0, 10);
		await env.DB.prepare("INSERT OR REPLACE INTO usage(key,value) VALUES (?1,2000)").bind(`demo.sessions.${day}`).run();
		expect((await grant()).status).toBe(503);
	});
});
