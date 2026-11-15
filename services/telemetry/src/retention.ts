// SPDX-License-Identifier: AGPL-3.0-only

import { sendAlerts } from "./alerts";
import { Budget, limitsFrom, releaseStoredBytes, utcDay, WRITES_PER_ROW, withWrites } from "./budget";
import type { PayloadKind } from "./payloads";
import { deleteObjects } from "./storage";

const DAY = 24 * 60 * 60 * 1000;

/** Retention by time received, in days. */
export const RETENTION_DAYS = { metrics: 90, diagnostics: 365, reports: 730, events: 400 } as const;
/** Daily usage counters are kept this many days, monthly ones this many months. */
export const USAGE_DAYS = 40;
export const USAGE_MONTHS = 13;

/**
 * Share of the daily D1 write budget one run may spend on deletes (each deleted row costs about
 * WRITES_PER_ROW rows written). Rows left over are deleted on later runs.
 */
const RETENTION_WRITE_SHARE = 0.25;
// Chunks keep one run well inside the D1 and subrequest limits of the Workers Free plan.
const OBJECT_CHUNK = 1000;
const OBJECT_CHUNKS = 3;
const EVENT_CHUNK = 2500;
const EVENT_CHUNKS = 4;

export interface RetentionResult {
	metrics: number;
	diagnostics: number;
	reports: number;
	events: number;
	storedBytes: number;
	alerts: string[];
}

/**
 * Scheduled daily: deletes data past retention (R2 objects first, then rows), prunes old usage
 * counters, resets `r2.bytes` to the sizes in the tables, then sends budget alerts.
 */
export async function runRetention(env: Env, now: Date): Promise<RetentionResult> {
	const limits = limitsFrom(env);
	const cutoff = (days: number) => new Date(now.getTime() - days * DAY).toISOString();
	const deleter = new Deleter(env, Math.floor(limits.d1MaxWritesDay * RETENTION_WRITE_SHARE));

	// Rows with R2 objects first: they cost storage.
	const metrics = await deleter.withObjects("payloads", cutoff(RETENTION_DAYS.metrics), "metrics");
	const diagnostics = await deleter.withObjects("payloads", cutoff(RETENTION_DAYS.diagnostics), "diagnostics");
	const reports = await deleter.withObjects("reports", cutoff(RETENTION_DAYS.reports));
	const events = await deleter.events(cutoff(RETENTION_DAYS.events));

	const [days, months, reconciled] = await env.DB.batch<{ value: number }>([
		env.DB.prepare(
			"DELETE FROM usage WHERE key GLOB '*.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND substr(key, -10) < ?1",
		).bind(utcDay(new Date(now.getTime() - USAGE_DAYS * DAY))),
		env.DB.prepare("DELETE FROM usage WHERE key GLOB '*.[0-9][0-9][0-9][0-9]-[0-9][0-9]' AND substr(key, -7) < ?1").bind(
			new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - USAGE_MONTHS, 1)).toISOString().slice(0, 7),
		),
		env.DB.prepare(
			`INSERT INTO usage (key, value)
			VALUES ('r2.bytes', (SELECT coalesce(sum(size), 0) FROM payloads) + (SELECT coalesce(sum(size), 0) FROM reports))
			ON CONFLICT(key) DO UPDATE SET value = excluded.value RETURNING value`,
		),
	]);
	deleter.writes += days.meta.changes + months.meta.changes + 1;
	const storedBytes = reconciled.results[0]?.value ?? 0;

	const alerts = await sendAlerts(env, now, limits);
	deleter.writes += alerts.markers;
	await new Budget(limits, now).add(env.DB, withWrites({}, deleter.writes)).run();

	const result = { metrics, diagnostics, reports, events, storedBytes, alerts: alerts.subjects };
	console.log(`retention: ${JSON.stringify(result)}`);
	return result;
}

/** Deletes in chunks while the run's share of the D1 write budget lasts; counts rows written. */
class Deleter {
	writes = 0;

	constructor(
		private readonly env: Env,
		private readonly allowance: number,
	) {}

	/** How many more rows (at most `chunk`) this run may delete. */
	private room(chunk: number): number {
		return Math.max(0, Math.min(chunk, Math.floor((this.allowance - this.writes) / WRITES_PER_ROW)));
	}

	/** Deletes rows received before `cutoff` (of one payload kind), their R2 objects, and their bytes in `r2.bytes`. */
	async withObjects(table: "payloads" | "reports", cutoff: string, kind?: PayloadKind): Promise<number> {
		const { DB, BUCKET } = this.env;
		let deleted = 0;
		for (let chunk = 0; chunk < OBJECT_CHUNKS; chunk++) {
			const limit = this.room(OBJECT_CHUNK);
			if (limit === 0) break;
			const select = kind
				? DB.prepare("SELECT id, r2_key, size FROM payloads WHERE kind = ?3 AND received < ?1 LIMIT ?2").bind(cutoff, limit, kind)
				: DB.prepare(`SELECT id, r2_key, size FROM ${table} WHERE received < ?1 LIMIT ?2`).bind(cutoff, limit);
			const { results } = await select.all<{ id: string; r2_key: string; size: number }>();
			if (results.length === 0) break;
			await deleteObjects(
				BUCKET,
				results.map((row) => row.r2_key).filter((key) => key !== ""),
			);
			const bytes = results.reduce((sum, row) => sum + row.size, 0);
			await DB.batch([
				DB.prepare(`DELETE FROM ${table} WHERE id IN (SELECT value FROM json_each(?1))`).bind(
					JSON.stringify(results.map((row) => row.id)),
				),
				...(bytes > 0 ? [releaseStoredBytes(DB, bytes)] : []),
			]);
			this.writes += results.length * WRITES_PER_ROW + (bytes > 0 ? 1 : 0);
			deleted += results.length;
			if (results.length < limit) break;
		}
		return deleted;
	}

	async events(cutoff: string): Promise<number> {
		let deleted = 0;
		for (let chunk = 0; chunk < EVENT_CHUNKS; chunk++) {
			const limit = this.room(EVENT_CHUNK);
			if (limit === 0) break;
			const result = await this.env.DB.prepare(
				"DELETE FROM events WHERE id IN (SELECT id FROM events WHERE received < ?1 LIMIT ?2)",
			)
				.bind(cutoff, limit)
				.run();
			this.writes += result.meta.changes * WRITES_PER_ROW;
			deleted += result.meta.changes;
			if (result.meta.changes < limit) break;
		}
		return deleted;
	}
}
