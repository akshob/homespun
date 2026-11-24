// SPDX-License-Identifier: AGPL-3.0-only

import { Budget, limitsFrom, WRITES_PER_ROW, withWrites } from "./budget";
import { deleteObjects } from "./storage";
import { accountCleanup, installDigest } from "./writes";

/**
 * DELETE /v1/installs/<install>: removes every event, payload and report of the install,
 * The tombstone and publication cancellation are atomic with respect to D1 admissions.
 * Delete only snapshotted rows after their objects; interrupted writers keep cleanup pointers.
 */
export async function deleteInstall(install: string, env: Env): Promise<Response> {
	const digest = await installDigest(install);
	const fenced = await env.DB.batch([
		env.DB.prepare("INSERT OR IGNORE INTO erased_installs (digest) VALUES (?1)").bind(digest),
		env.DB.prepare("UPDATE object_writes SET state = 'cleanup' WHERE install = ?1 AND state = 'pending'").bind(install),
	]);
	await accountCleanup(env, fenced[0].meta.changes * 2 + fenced[1].meta.changes * WRITES_PER_ROW);
	const [payloads, reports, pending] = await env.DB.batch<{ id: string; r2_key: string; size: number }>([
		env.DB.prepare("SELECT id, r2_key, size FROM payloads WHERE install = ?1").bind(install),
		env.DB.prepare("SELECT id, r2_key, size FROM reports WHERE install = ?1").bind(install),
		env.DB.prepare("SELECT r2_key FROM object_writes WHERE install = ?1").bind(install),
	]);
	const stored = [...payloads.results, ...reports.results];
	await deleteObjects(
		env.BUCKET,
		[...stored, ...pending.results].map((row) => row.r2_key).filter((key) => key !== ""),
	);
	const payloadIDs = JSON.stringify(payloads.results.map((row) => row.id));
	const reportIDs = JSON.stringify(reports.results.map((row) => row.id));
	const results = await env.DB.batch([
		// Compute from rows still present *inside* the deletion transaction. Another erasure or
		// retention run may already have released a snapshotted row's bytes.
		env.DB.prepare(`UPDATE usage SET value = max(0, value -
			(SELECT coalesce(sum(size), 0) FROM payloads WHERE id IN (SELECT value FROM json_each(?1))) -
			(SELECT coalesce(sum(size), 0) FROM reports WHERE id IN (SELECT value FROM json_each(?2))))
			WHERE key = 'r2.bytes'`).bind(payloadIDs, reportIDs),
		env.DB.prepare("DELETE FROM events WHERE install = ?1").bind(install),
		env.DB.prepare("DELETE FROM payloads WHERE id IN (SELECT value FROM json_each(?1))").bind(payloadIDs),
		env.DB.prepare("DELETE FROM reports WHERE id IN (SELECT value FROM json_each(?1))").bind(reportIDs),
	]);
	const deleted = results.slice(1).reduce((sum, result) => sum + result.meta.changes, 0);
	if (deleted > 0) {
		const writes = deleted * WRITES_PER_ROW + results[0].meta.changes;
		await new Budget(limitsFrom(env), new Date()).add(env.DB, withWrites({}, writes)).run();
	}
	return new Response(null, { status: 204 });
}
