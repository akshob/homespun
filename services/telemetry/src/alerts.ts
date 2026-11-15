// SPDX-License-Identifier: AGPL-3.0-only

import { flagKeys, readUsage, usageKeys, utcDay, type Limits, type UsageRow } from "./budget";

export const ALERT_FROM = { email: "reports@homespun.photos", name: "Homespun Telemetry" };
/** Percent of a monthly R2 cap at which the owner is emailed (once per threshold and month). */
export const ALERT_THRESHOLDS = [50, 75, 90] as const;

const DAY = 24 * 60 * 60 * 1000;

interface Alert {
	subject: string;
	intro: string;
	/** `usage` keys remembering that this alert was sent. */
	markers: string[];
}

/**
 * Emails the owner (REPORT_TO) when stored R2 bytes or this month's R2 writes cross 50/75/90% of
 * their caps, and when yesterday hit a daily cap. Alerts are not counted as report emails.
 * Returns the subjects sent and how many marker rows were written.
 */
export async function sendAlerts(env: Env, now: Date, limits: Limits): Promise<{ subjects: string[]; markers: number }> {
	const yesterday = new Date(now.getTime() - DAY);
	const day = usageKeys(yesterday);
	const flags = flagKeys(yesterday);
	const monthly = [
		{
			name: "storage",
			key: day.storedBytes,
			cap: limits.r2MaxBytes,
			month: utcDay(now).slice(0, 7),
			subject: (percent: number) => `R2 storage at ${percent}% of its budget`,
		},
		{
			name: "writes",
			key: day.monthPuts,
			cap: limits.r2MaxPutsMonth,
			month: utcDay(yesterday).slice(0, 7),
			subject: (percent: number) => `R2 writes at ${percent}% of this month's budget`,
		},
	];
	const marker = (name: string, threshold: number, month: string) => `alert.${name}.${threshold}.${month}`;
	const dailyMarker = `alert.daily.${utcDay(yesterday)}`;

	const { results } = await readUsage(env.DB, [
		...Object.values(day),
		...Object.values(flags),
		...monthly.flatMap((check) => ALERT_THRESHOLDS.map((threshold) => marker(check.name, threshold, check.month))),
		dailyMarker,
	]).all<UsageRow>();
	const usage = new Map(results.map((row) => [row.key, row.value]));
	const value = (key: string) => usage.get(key) ?? 0;

	const alerts: Alert[] = [];
	for (const check of monthly) {
		if (check.cap <= 0) continue;
		const percent = Math.floor((value(check.key) * 100) / check.cap);
		const crossed = ALERT_THRESHOLDS.filter((threshold) => percent >= threshold);
		const highest = crossed.at(-1);
		if (highest === undefined || usage.has(marker(check.name, highest, check.month))) continue;
		alerts.push({
			subject: `[Homespun telemetry] ${check.subject(percent)}`,
			intro: `${check.subject(percent)} (alert threshold ${highest}%).`,
			markers: crossed.map((threshold) => marker(check.name, threshold, check.month)),
		});
	}

	const hit: string[] = [];
	if (usage.has(flags.events) || (limits.eventsMaxDay > 0 && value(day.dayEvents) >= limits.eventsMaxDay)) {
		hit.push("events (batches were refused with 503 and stay queued in the app)");
	}
	if (limits.reportEmailsMaxDay > 0 && value(day.dayEmails) >= limits.reportEmailsMaxDay) {
		hit.push("report emails (later reports were stored but not emailed)");
	}
	if (usage.has(flags.d1)) hit.push("D1 writes (events, metrics or diagnostics were refused)");
	if (usage.has(flags.r2)) hit.push("R2 (metrics or diagnostics were refused, or reports kept without R2)");
	if (hit.length > 0 && !usage.has(dailyMarker)) {
		alerts.push({
			subject: `[Homespun telemetry] Daily caps reached on ${utcDay(yesterday)}`,
			intro: `On ${utcDay(yesterday)} (UTC) these daily caps were reached:\n${hit.map((line) => `- ${line}`).join("\n")}`,
			markers: [dailyMarker],
		});
	}
	if (alerts.length === 0) return { subjects: [], markers: 0 };

	const to = env.REPORT_TO?.trim();
	if (!to || !env.MAIL) {
		console.warn(`budget alerts not sent, REPORT_TO or MAIL is not configured: ${alerts.map((alert) => alert.subject).join("; ")}`);
		return { subjects: [], markers: 0 };
	}
	const table = usageTable(value, day, limits, yesterday);
	const subjects: string[] = [];
	const markers: string[] = [];
	for (const alert of alerts) {
		try {
			await env.MAIL.send({ from: ALERT_FROM, to, subject: alert.subject, text: `${alert.intro}\n\n${table}` });
			subjects.push(alert.subject);
			markers.push(...alert.markers);
		} catch (error) {
			console.error(`budget alert "${alert.subject}" failed: ${error instanceof Error ? error.message : String(error)}`);
		}
	}
	if (markers.length > 0) {
		const values = markers.map((_, index) => `(?${index + 1}, 1)`).join(", ");
		await env.DB.prepare(`INSERT OR IGNORE INTO usage (key, value) VALUES ${values}`)
			.bind(...markers)
			.run();
	}
	return { subjects, markers: markers.length };
}

function usageTable(
	value: (key: string) => number,
	keys: ReturnType<typeof usageKeys>,
	limits: Limits,
	yesterday: Date,
): string {
	const day = utcDay(yesterday);
	const rows: [string, number, number, boolean?][] = [
		["R2 stored now", value(keys.storedBytes), limits.r2MaxBytes, true],
		[`R2 writes in ${day.slice(0, 7)}`, value(keys.monthPuts), limits.r2MaxPutsMonth],
		[`R2 writes on ${day}`, value(keys.dayPuts), limits.r2MaxPutsDay],
		[`R2 bytes added on ${day}`, value(keys.dayBytes), limits.r2MaxBytesDay, true],
		[`Events on ${day}`, value(keys.dayEvents), limits.eventsMaxDay],
		[`Report emails on ${day}`, value(keys.dayEmails), limits.reportEmailsMaxDay],
		[`D1 rows written on ${day} (estimate)`, value(keys.dayWrites), limits.d1MaxWritesDay],
	];
	const lines = rows.map(([label, used, cap, bytes]) => {
		const percent = cap > 0 ? `${Math.floor((used * 100) / cap)}%` : "-";
		const amount = bytes ? `${formatBytes(used)} of ${formatBytes(cap)}` : `${count(used)} of ${count(cap)}`;
		return `  ${label.padEnd(36)} ${amount} (${percent})`;
	});
	return [
		"Usage (UTC) against the caps:",
		...lines,
		"",
		"Metrics and diagnostics are refused at 90% of an R2 or D1 cap; events at the daily event cap or 90% of",
		"the D1 cap. Reports use R2 up to 100%, then are kept in D1 only. The caps are vars in wrangler.jsonc.",
		"All counters:",
		'  npx wrangler d1 execute homespun-telemetry --remote --command "SELECT * FROM usage ORDER BY key"',
		"",
	].join("\n");
}

function count(value: number): string {
	return value.toLocaleString("en-US");
}

export function formatBytes(bytes: number): string {
	if (bytes >= 1e9) return `${(bytes / 1e9).toFixed(2)} GB`;
	if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(1)} MB`;
	if (bytes >= 1e3) return `${(bytes / 1e3).toFixed(1)} kB`;
	return `${bytes} B`;
}
