// SPDX-License-Identifier: AGPL-3.0-only

import { deleteObjects } from "./storage";

/**
 * DELETE /v1/installs/<install>: removes every event, payload and report of the install,
 * R2 objects first so a failure leaves rows that a retry can still find. Always 204.
 */
export async function deleteInstall(install: string, env: Env): Promise<Response> {
	const [payloads, reports] = await env.DB.batch<{ r2_key: string }>([
		env.DB.prepare("SELECT r2_key FROM payloads WHERE install = ?1").bind(install),
		env.DB.prepare("SELECT r2_key FROM reports WHERE install = ?1").bind(install),
	]);
	await deleteObjects(env.BUCKET, [...payloads.results, ...reports.results].map((row) => row.r2_key));
	await env.DB.batch([
		env.DB.prepare("DELETE FROM events WHERE install = ?1").bind(install),
		env.DB.prepare("DELETE FROM payloads WHERE install = ?1").bind(install),
		env.DB.prepare("DELETE FROM reports WHERE install = ?1").bind(install),
	]);
	return new Response(null, { status: 204 });
}
