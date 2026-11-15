// SPDX-License-Identifier: AGPL-3.0-only

import { handleEvents } from "./events";
import { errorResponse, HttpError, json, KB, MB, readJsonBody, type JsonBody } from "./http";
import { deleteInstall } from "./installs";
import { handlePayload } from "./payloads";
import { handleReport } from "./reports";
import { runRetention } from "./retention";
import { parseInstall } from "./validate";

interface PostRoute {
	maxBytes: number;
	/** Also apply the stricter per-IP report limit. */
	report?: boolean;
	handle(body: JsonBody, env: Env): Promise<Response>;
}

const POST_ROUTES: Record<string, PostRoute> = {
	"/v1/events": { maxBytes: 64 * KB, handle: (body, env) => handleEvents(body.value, env) },
	"/v1/metrics": { maxBytes: 512 * KB, handle: (body, env) => handlePayload("metrics", body, env) },
	"/v1/diagnostics": { maxBytes: 1 * MB, handle: (body, env) => handlePayload("diagnostics", body, env) },
	"/v1/reports": { maxBytes: 2 * MB, report: true, handle: handleReport },
};

const INSTALL_PATH = /^\/v1\/installs\/([^/]+)$/;

export default {
	async fetch(request, env): Promise<Response> {
		try {
			return await route(request, env);
		} catch (error) {
			if (error instanceof HttpError) return errorResponse(error);
			console.error("internal error", error);
			return errorResponse(new HttpError(500, "internal error"));
		}
	},

	async scheduled(controller, env): Promise<void> {
		await runRetention(env, new Date(controller.scheduledTime));
	},
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
	const { pathname } = new URL(request.url);

	if (pathname === "/v1/health") {
		requireMethod(request, "GET");
		return json({ ok: true });
	}

	const post = Object.hasOwn(POST_ROUTES, pathname) ? POST_ROUTES[pathname] : undefined;
	if (post) {
		requireMethod(request, "POST");
		requireKey(request, env);
		await rateLimit(request, env, post.report === true);
		return post.handle(await readJsonBody(request, post.maxBytes), env);
	}

	const installPath = INSTALL_PATH.exec(pathname);
	if (installPath) {
		requireMethod(request, "DELETE");
		requireKey(request, env);
		await rateLimit(request, env, false);
		return deleteInstall(parseInstall(installPath[1]), env);
	}

	throw new HttpError(404, "not found");
}

function requireMethod(request: Request, method: string): void {
	if (request.method !== method) throw new HttpError(405, "method not allowed", { Allow: method });
}

function requireKey(request: Request, env: Env): void {
	if (!env.APP_KEY) {
		console.error("APP_KEY is not configured");
		throw new HttpError(500, "server misconfigured");
	}
	if (request.headers.get("X-Homespun-Key") !== env.APP_KEY) throw new HttpError(401, "missing or invalid key");
}

/** Per-IP limits from the Rate Limiting bindings. Fails open if a limiter is missing or errors. */
async function rateLimit(request: Request, env: Env, report: boolean): Promise<void> {
	const key = request.headers.get("CF-Connecting-IP") ?? "unknown";
	const limiters = report ? [env.LIMITER, env.REPORT_LIMITER] : [env.LIMITER];
	for (const limiter of limiters) {
		if (!limiter) continue;
		let allowed = true;
		try {
			allowed = (await limiter.limit({ key })).success;
		} catch (error) {
			console.error("rate limiter failed", error);
		}
		if (!allowed) throw new HttpError(429, "too many requests", { "Retry-After": "60" });
	}
}
