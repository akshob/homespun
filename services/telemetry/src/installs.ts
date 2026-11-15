// SPDX-License-Identifier: AGPL-3.0-only

import { Budget, limitsFrom, releaseStoredBytes, WRITES_PER_ROW, withWrites } from "./budget";
import { deleteObjects } from "./storage";

/**
 * DELETE /v1/installs/<install>: removes every event, payload and report of the install,
 * R2 objects first so a failure leaves rows that a retry can still find. Always 204, and never
 * refused by the budget.
 */
export async function deleteInstall(install: string, env: Env): Promise<Response> {
	const [payloads, reports] = await env.DB.batch<{ r2_key: string; size: number }>([
		env.DB.prepare("SELECT r2_key, size FROM payloads WHERE install = ?1").bind(install),
		env.DB.prepare("SELECT r2_key, size FROM reports WHERE install = ?1").bind(install),
	]);
	const stored = [...payloads.results, ...reports.results];
	await deleteObjects(
		env.BUCKET,
		stored.map((row) => row.r2_key).filter((key) => key !== ""),
	);
	const bytes = stored.reduce((sum, row) => sum + row.size, 0);
	const results = await env.DB.batch([
		env.DB.prepare("DELETE FROM events WHERE install = ?1").bind(install),
		env.DB.prepare("DELETE FROM payloads WHERE install = ?1").bind(install),
		env.DB.prepare("DELETE FROM reports WHERE install = ?1").bind(install),
		...(bytes > 0 ? [releaseStoredBytes(env.DB, bytes)] : []),
	]);
	const deleted = results.slice(0, 3).reduce((sum, result) => sum + result.meta.changes, 0);
	if (deleted > 0) {
		const writes = deleted * WRITES_PER_ROW + (bytes > 0 ? 1 : 0);
		await new Budget(limitsFrom(env), new Date()).add(env.DB, withWrites({}, writes)).run();
	}
	return new Response(null, { status: 204 });
}
