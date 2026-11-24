// SPDX-License-Identifier: AGPL-3.0-only

import { Budget, limitsFrom, withWrites } from "./budget";
import { HttpError } from "./http";
import { deleteObjects } from "./storage";

/** Conservative reservation for journal insert/delete, indexes, and failure-state update. */
export const OBJECT_WRITE_WRITES = 12;
const ABANDONED_MS = 60 * 60 * 1000;

export function reserveWrite(env: Env, key: string, install: string | null, size: number, now: Date): D1PreparedStatement {
	return env.DB.prepare(
		"INSERT INTO object_writes (r2_key, install, created, checked, size) VALUES (?1, ?2, ?3, ?3, ?4)",
	).bind(key, install, now.toISOString(), size);
}

export async function assertInstallLive(env: Env, install: string | null): Promise<void> {
	if (install !== null && await env.DB.prepare("SELECT 1 FROM erased_installs WHERE install = ?1").bind(install).first()) {
		throw new HttpError(410, "install erased");
	}
}

/** Call only after this writer's PUT has settled; never from an erasure snapshot. */
export async function cleanOwnWrite(env: Env, key: string): Promise<void> {
	await env.DB.prepare("UPDATE object_writes SET state = 'cleanup', settled = 1 WHERE r2_key = ?1").bind(key).run();
	await env.BUCKET.delete(key);
	await forgetSettled(env, [key]);
}

/** Remove only pointers certified settled BEFORE the caller's acknowledged R2 deletion. */
async function forgetSettled(env: Env, keys: string[]): Promise<number> {
	if (keys.length === 0) return 0;
	const list = JSON.stringify(keys);
	const results = await env.DB.batch([
		env.DB.prepare(`UPDATE usage SET value = max(0, value - (
			SELECT coalesce(sum(size), 0) FROM object_writes
			WHERE settled = 1 AND r2_key IN (SELECT value FROM json_each(?1)))) WHERE key = 'r2.bytes'`).bind(list),
		env.DB.prepare("DELETE FROM object_writes WHERE settled = 1 AND r2_key IN (SELECT value FROM json_each(?1))").bind(list),
	]);
	return results[0].meta.changes + results[1].meta.changes * 4;
}

/**
 * An abandoned PUT can have committed before its isolate died. Cancel publication, erase its
 * object, and retain the pointer if no writer acknowledged completion. Even an arbitrarily late
 * PUT then stays discoverable on subsequent sweeps. Never infer settlement from a lease timeout.
 */
export async function reconcileWrites(env: Env, now: Date, allowance: number): Promise<number> {
	const limit = Math.max(0, Math.min(1000, Math.floor(allowance / OBJECT_WRITE_WRITES)));
	if (limit === 0) return 0;
	const canceled = await env.DB.prepare(
		`UPDATE object_writes SET state = 'cleanup' WHERE r2_key IN
			(SELECT r2_key FROM object_writes WHERE state = 'pending' AND created < ?1 ORDER BY created LIMIT ?2)`,
	).bind(new Date(now.getTime() - ABANDONED_MS).toISOString(), limit).run();
	const { results } = await env.DB.prepare(
		"SELECT r2_key, settled FROM object_writes WHERE state = 'cleanup' ORDER BY checked, r2_key LIMIT ?1",
	).bind(limit).all<{ r2_key: string; settled: number }>();
	await deleteObjects(env.BUCKET, results.map((row) => row.r2_key));
	let writes = canceled.meta.changes * 4;
	writes += await forgetSettled(env, results.filter((row) => row.settled === 1).map((row) => row.r2_key));
	if (results.length > 0) {
		const checked = await env.DB.prepare(
			"UPDATE object_writes SET checked = ?1 WHERE r2_key IN (SELECT value FROM json_each(?2))",
		).bind(now.toISOString(), JSON.stringify(results.map((row) => row.r2_key))).run();
		writes += checked.meta.changes * 2;
	}
	return writes;
}

export async function accountCleanup(env: Env, writes: number, now = new Date()): Promise<void> {
	if (writes > 0) await new Budget(limitsFrom(env), now).add(env.DB, withWrites({}, writes)).run();
}
