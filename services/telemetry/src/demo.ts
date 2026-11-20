// SPDX-License-Identifier: AGPL-3.0-only

import { Budget, busy, withWrites } from "./budget";
import { HttpError, isObject, json, MB, readJsonBody } from "./http";

declare global {
	interface Env {
		DEMO_CODE_SHA256?: string;
		DEMO_SIGNING_KEY?: string;
	}
	namespace Cloudflare {
		interface Env {
			DEMO_CODE_SHA256?: string;
			DEMO_SIGNING_KEY?: string;
		}
	}
}

export interface DemoManifest {
	version: number;
	totalBytes: number;
	files: { file: string; sha256: string; size: number; kind: string; width: number; height: number; date: string; category: string }[];
}

const encoder = new TextEncoder();
const LIFETIME = 900;
const forbidden = () => new HttpError(403, "forbidden");
const hex = (bytes: ArrayBuffer) => Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
const unhex = (text: string) => Uint8Array.from(text.match(/../g) ?? [], (b) => Number.parseInt(b, 16));

export async function digest(text: string): Promise<string> {
	return hex(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
}

async function sign(text: string, env: Env): Promise<string> {
	if (!env.DEMO_SIGNING_KEY || env.DEMO_SIGNING_KEY.length < 32) throw new HttpError(503, "unavailable");
	const key = await crypto.subtle.importKey("raw", encoder.encode(env.DEMO_SIGNING_KEY), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
	return hex(await crypto.subtle.sign("HMAC", key, encoder.encode(text)));
}

function equal(left: string, right: string): boolean {
	return /^[a-f0-9]{64}$/.test(left) && /^[a-f0-9]{64}$/.test(right)
		&& crypto.subtle.timingSafeEqual(unhex(left), unhex(right));
}

export async function sessionToken(manifestHash: string, env: Env, now = Date.now()): Promise<string> {
	const payload = `${Math.floor(now / 1000) + LIFETIME}.${manifestHash}`;
	return `${payload}.${await sign(`${payload}.${env.DEMO_CODE_SHA256}`, env)}`;
}

export async function verifyToken(token: string, env: Env, now = Date.now()): Promise<string> {
	const match = /^(\d{10})\.([a-f0-9]{64})\.([a-f0-9]{64})$/.exec(token);
	if (!match) throw forbidden();
	const expires = Number(match[1]), seconds = Math.floor(now / 1000);
	if (expires <= seconds || expires > seconds + LIFETIME) throw forbidden();
	if (!equal(match[3], await sign(`${match[1]}.${match[2]}.${env.DEMO_CODE_SHA256}`, env))) throw forbidden();
	return match[2];
}

export function parseManifest(value: unknown): DemoManifest {
	if (!isObject(value) || value.version !== 1 || !Array.isArray(value.files) || value.files.length !== 16) {
		throw new HttpError(503, "unavailable");
	}
	const names = new Set<string>();
	let total = 0;
	for (const f of value.files) {
		if (!isObject(f) || typeof f.file !== "string" || !/^demo-[a-z0-9-]+\.(heic|jpg)$/.test(f.file)
			|| names.has(f.file) || typeof f.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(f.sha256)
			|| !Number.isSafeInteger(f.size) || (f.size as number) <= 0 || (f.size as number) > 8 * MB
			|| f.kind !== "photo" || !Number.isInteger(f.width) || !Number.isInteger(f.height)
			|| (f.width as number) <= 0 || (f.height as number) <= 0 || (f.width as number) > 4032 || (f.height as number) > 4032
			|| typeof f.date !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)$/.test(f.date)
			|| !Number.isFinite(Date.parse(f.date)) || typeof f.category !== "string" || !/^[a-z-]{1,40}$/.test(f.category)) {
			throw new HttpError(503, "unavailable");
		}
		names.add(f.file);
		total += f.size as number;
	}
	if (total !== value.totalBytes || total > 64 * MB) throw new HttpError(503, "unavailable");
	// Return only the public contract, never arbitrary metadata accidentally added by upload tooling.
	return { version: 1, totalBytes: total, files: value.files.map(({ file, sha256, size, kind, width, height, date, category }) =>
		({ file, sha256, size, kind, width, height, date, category })) };
}

async function manifest(env: Env): Promise<DemoManifest> {
	const object = await env.DEMO_BUCKET.get("v1/manifest.json");
	if (!object || object.size > 32_768) throw new HttpError(503, "unavailable");
	return parseManifest(await object.json());
}

/** Separate, small demo allowances, also charged against telemetry's shared D1 write budget.
 * Atomic counter reservations can only over-count on a later failure, never grant free reads. */
async function charge(env: Env, type: "sessions" | "reads" | "bytes", amount = 1): Promise<void> {
	const now = new Date(), day = now.toISOString().slice(0, 10);
	const budget = await Budget.load(env, now), writes = withWrites({}, 8);
	if (!budget.allows(writes, 90)) throw busy(now);
	await budget.add(env.DB, writes).run();
	const caps = type === "sessions" ? [[day, 200]] as const : type === "reads"
		? [[day, 1000], [day.slice(0, 7), 20_000]] as const : [[day, 1_000_000_000]] as const;
	for (const [period, cap] of caps) {
		const result = await env.DB.prepare(`INSERT INTO usage (key, value) SELECT ?1, ?2 WHERE ?2 <= ?3
			ON CONFLICT(key) DO UPDATE SET value = value + excluded.value WHERE value + excluded.value <= ?3 RETURNING value`)
			.bind(`demo.${type}.${period}`, amount, cap).all();
		if (result.results.length === 0) throw busy(now);
	}
}

async function limit(request: Request, env: Env, file: boolean): Promise<void> {
	const limiter = file ? env.DEMO_FILE_LIMITER : env.DEMO_LIMITER;
	try {
		if ((await limiter.limit({ key: request.headers.get("CF-Connecting-IP") ?? "unknown" })).success) return;
	} catch { /* Fail closed: this gate protects private media. */ }
	throw forbidden();
}

export async function handleDemo(request: Request, env: Env): Promise<Response> {
	const path = new URL(request.url).pathname;
	if (path === "/v1/demo/session") {
		if (request.method !== "POST") throw forbidden();
		await limit(request, env, false);
		await charge(env, "sessions");
		if (!env.DEMO_CODE_SHA256 || !/^[a-f0-9]{64}$/.test(env.DEMO_CODE_SHA256)) throw new HttpError(503, "unavailable");
		const window = Math.floor(Date.now() / (LIFETIME * 1000));
		const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
		const counter = await sign(`lockout.${window}.${ip}`, env);
		const failures = await env.DB.prepare("SELECT failures FROM demo_lockouts WHERE key = ?1").bind(counter).first<number>("failures");
		if ((failures ?? 0) >= 5) throw forbidden();
		const body = await readJsonBody(request, 256);
		const code = typeof body.value.code === "string" ? body.value.code.toUpperCase().replace(/[-\s]/g, "") : "";
		if (!equal(await digest(code), env.DEMO_CODE_SHA256)) {
			await env.DB.prepare(`INSERT INTO demo_lockouts (key, failures, expires) VALUES (?1, 1, ?2)
				ON CONFLICT(key) DO UPDATE SET failures = failures + 1`).bind(counter, (window + 1) * LIFETIME).run();
			throw forbidden();
		}
		await charge(env, "reads");
		const media = await manifest(env);
		const token = await sessionToken(await digest(JSON.stringify(media)), env);
		return json({ manifest: media, token, expiresAt: Number(token.split(".")[0]) });
	}

	const file = /^\/v1\/demo\/files\/(demo-[a-z0-9-]+\.(?:heic|jpg))$/.exec(path)?.[1];
	if (!file || request.method !== "GET") throw forbidden();
	await limit(request, env, true);
	const hash = await verifyToken((request.headers.get("Authorization") ?? "").replace(/^Bearer /, ""), env);
	await charge(env, "reads", 2);
	const media = await manifest(env);
	if (!equal(hash, await digest(JSON.stringify(media)))) throw forbidden();
	const entry = media.files.find((f) => f.file === file);
	if (!entry) throw forbidden();
	await charge(env, "bytes", entry.size);
	const object = await env.DEMO_BUCKET.get(`v1/${file}`);
	if (!object || object.size !== entry.size) throw new HttpError(503, "unavailable");
	return new Response(object.body, { headers: {
		"Content-Type": file.endsWith(".jpg") ? "image/jpeg" : "image/heic",
		"Content-Length": String(entry.size), "Cache-Control": "private, no-store",
		"X-Content-Type-Options": "nosniff", "X-Robots-Tag": "noindex, noimageindex",
	} });
}
