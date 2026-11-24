// SPDX-License-Identifier: AGPL-3.0-only

import { env, exports } from "cloudflare:workers";
import worker from "../src/index";

export const KEY = "homespun-app-v1";
export const APP = { version: "1.0", build: "42", channel: "testflight" };
export const DEVICE = { model: "iPhone18,1", os: "27.2", family: "iphone" };

export function newInstall(): string {
	return crypto.randomUUID();
}

/** A fresh client address per request keeps the per-IP rate limits out of unrelated tests. */
export function randomIp(): string {
	return `2001:db8:${Array.from(crypto.getRandomValues(new Uint16Array(6)), (part) => part.toString(16)).join(":")}`;
}

export interface RequestOptions {
	/** `null` omits the header. */
	key?: string | null;
	ip?: string;
	/** `null` omits the header. Defaults to application/json when there is a body. */
	contentType?: string | null;
	/** Raw body instead of JSON-encoding `json`. */
	body?: BodyInit;
}

export function makeRequest(method: string, path: string, json?: unknown, options: RequestOptions = {}): Request {
	const headers = new Headers({ "CF-Connecting-IP": options.ip ?? randomIp() });
	const key = options.key === undefined ? KEY : options.key;
	if (key !== null) headers.set("X-Homespun-Key", key);
	const body = options.body ?? (json === undefined ? undefined : JSON.stringify(json));
	const contentType = options.contentType === undefined ? (body === undefined ? null : "application/json") : options.contentType;
	if (contentType !== null) headers.set("Content-Type", contentType);
	return new Request(`https://telemetry.homespun.photos${path}`, { method, headers, body });
}

/** Sends a request through the Worker with the bindings from wrangler.jsonc (Miniflare D1, R2, limits, mail). */
export function send(method: string, path: string, json?: unknown, options?: RequestOptions): Promise<Response> {
	return exports.default.fetch(makeRequest(method, path, json, options));
}

export function post(path: string, json: unknown, options?: RequestOptions): Promise<Response> {
	return send("POST", path, json, options);
}

/** Calls the fetch handler directly with some bindings replaced, e.g. a fake MAIL or LIMITER. */
export function sendWith(
	overrides: Partial<Record<keyof Env, unknown>>,
	method: string,
	path: string,
	json?: unknown,
	options?: RequestOptions,
): Promise<Response> {
	const request = makeRequest(method, path, json, options) as Parameters<typeof worker.fetch>[0];
	return worker.fetch(request, { ...env, ...overrides } as Env);
}

export async function rows<T = Record<string, unknown>>(sql: string, ...params: unknown[]): Promise<T[]> {
	return (await env.DB.prepare(sql).bind(...params).all<T>()).results;
}

export async function objectText(key: string): Promise<string | null> {
	const object = await env.BUCKET.get(key);
	return object === null ? null : object.text();
}

/** A report email captured by a fake MAIL binding. */
export interface SentEmail {
	from: { email: string; name: string };
	to: string;
	replyTo?: string;
	subject: string;
	text: string;
}

export function fakeMail(options: { fail?: boolean } = {}) {
	const sent: SentEmail[] = [];
	return {
		sent,
		binding: {
			async send(message: SentEmail) {
				sent.push(message);
				if (options.fail) throw Object.assign(new Error("destination not verified"), { code: "E_RECIPIENT_NOT_ALLOWED" });
				return { messageId: "test" };
			},
		},
	};
}

/** Deterministic suspension at a storage boundary; no timers or live endpoints. */
export function barrier() {
	let enter!: () => void;
	let release!: () => void;
	const reached = new Promise<void>((resolve) => { enter = resolve; });
	const released = new Promise<void>((resolve) => { release = resolve; });
	return { reached, release, async hold() { enter(); await released; } };
}

/** Keep real D1 transactions, but intercept a selected batch before/after its atomic commit. */
export function interceptDatabase(intercept: (sql: string[], commit: () => Promise<D1Result<unknown>[]>) =>
	Promise<D1Result<unknown>[]>): D1Database {
	const statements = new WeakMap<D1PreparedStatement, { raw: D1PreparedStatement; sql: string }>();
	const wrap = (raw: D1PreparedStatement, sql: string): D1PreparedStatement => {
		const proxy = new Proxy(raw, {
			get(target, property) {
				if (property === "bind") return (...values: unknown[]) => wrap(target.bind(...values), sql);
				const value = Reflect.get(target, property);
				return typeof value === "function" ? value.bind(target) : value;
			},
		});
		statements.set(proxy, { raw, sql });
		return proxy;
	};
	return new Proxy(env.DB, {
		get(target, property) {
			if (property === "prepare") return (sql: string) => wrap(target.prepare(sql), sql);
			if (property === "batch") return (batch: D1PreparedStatement[]) =>
				intercept(batch.map((stmt) => statements.get(stmt)!.sql),
					() => target.batch(batch.map((stmt) => statements.get(stmt)!.raw)));
			const value = Reflect.get(target, property);
			return typeof value === "function" ? value.bind(target) : value;
		},
	});
}
