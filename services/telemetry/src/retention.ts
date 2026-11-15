// SPDX-License-Identifier: AGPL-3.0-only

import { PAYLOAD_KINDS } from "./payloads";
import { deleteObjects } from "./storage";

const DAY = 24 * 60 * 60 * 1000;

/** Retention by time received, in days. */
export const RETENTION_DAYS = { events: 400, payloads: 365, reports: 730 } as const;

// Deletes run in chunks so one cron run stays well inside D1 and subrequest limits
// (also on the Workers Free plan). Anything left over is removed on the next day's run.
const EVENT_CHUNK = 10_000;
const EVENT_CHUNKS_PER_RUN = 10;
const OBJECT_CHUNK = 1000;
const OBJECT_CHUNKS_PER_RUN = 3;

export interface RetentionResult {
	events: number;
	payloads: number;
	reports: number;
}

/** Scheduled daily: deletes old events, payloads (rows + R2) and reports (rows + R2). */
export async function runRetention(env: Env, now: Date): Promise<RetentionResult> {
	const cutoff = (days: number) => new Date(now.getTime() - days * DAY).toISOString();

	let events = 0;
	for (let chunk = 0; chunk < EVENT_CHUNKS_PER_RUN; chunk++) {
		const result = await env.DB.prepare(
			"DELETE FROM events WHERE id IN (SELECT id FROM events WHERE received < ?1 LIMIT ?2)",
		)
			.bind(cutoff(RETENTION_DAYS.events), EVENT_CHUNK)
			.run();
		events += result.meta.changes;
		if (result.meta.changes < EVENT_CHUNK) break;
	}

	let payloads = 0;
	for (const kind of PAYLOAD_KINDS) {
		payloads += await purgeWithObjects(
			env,
			env.DB.prepare("SELECT id, r2_key FROM payloads WHERE kind = ?1 AND received < ?2 LIMIT ?3").bind(
				kind,
				cutoff(RETENTION_DAYS.payloads),
				OBJECT_CHUNK,
			),
			"payloads",
		);
	}

	const reports = await purgeWithObjects(
		env,
		env.DB.prepare("SELECT id, r2_key FROM reports WHERE received < ?1 LIMIT ?2").bind(
			cutoff(RETENTION_DAYS.reports),
			OBJECT_CHUNK,
		),
		"reports",
	);

	const result = { events, payloads, reports };
	console.log(`retention: deleted ${JSON.stringify(result)}`);
	return result;
}

/** Deletes the R2 objects of the selected rows, then the rows; repeats while chunks are full. */
async function purgeWithObjects(
	env: Env,
	select: D1PreparedStatement,
	table: "payloads" | "reports",
): Promise<number> {
	let deleted = 0;
	for (let chunk = 0; chunk < OBJECT_CHUNKS_PER_RUN; chunk++) {
		const { results } = await select.all<{ id: string; r2_key: string }>();
		if (results.length === 0) break;
		await deleteObjects(
			env.BUCKET,
			results.map((row) => row.r2_key),
		);
		await env.DB.prepare(`DELETE FROM ${table} WHERE id IN (SELECT value FROM json_each(?1))`)
			.bind(JSON.stringify(results.map((row) => row.id)))
			.run();
		deleted += results.length;
		if (results.length < OBJECT_CHUNK) break;
	}
	return deleted;
}
