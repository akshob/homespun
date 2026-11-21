// SPDX-License-Identifier: AGPL-3.0-only

import { HttpError } from "./http";

/**
 * Hard usage caps, so a flood with the public app key can never run past the free tiers
 * (R2 bills beyond them; D1 and Workers stop working). Defaults are 80% of the free tiers and can
 * be changed with string vars in wrangler.jsonc. See README "Budget".
 */
export interface Limits {
	r2MaxBytes: number;
	r2MaxPutsMonth: number;
	r2MaxPutsDay: number;
	r2MaxBytesDay: number;
	eventsMaxDay: number;
	reportEmailsMaxDay: number;
	crashEmailsMaxDay: number;
	d1MaxWritesDay: number;
}

const LIMIT_VARS: Record<keyof Limits, readonly [variable: string, fallback: number]> = {
	// Reserve 64 MiB from the existing 8 GB allowance for the private demo bucket.
	r2MaxBytes: ["R2_MAX_BYTES", 7_932_891_136],
	r2MaxPutsMonth: ["R2_MAX_PUTS_MONTH", 800_000],
	r2MaxPutsDay: ["R2_MAX_PUTS_DAY", 25_000],
	r2MaxBytesDay: ["R2_MAX_BYTES_DAY", 250_000_000],
	eventsMaxDay: ["EVENTS_MAX_DAY", 20_000],
	reportEmailsMaxDay: ["REPORT_EMAILS_MAX_DAY", 50],
	crashEmailsMaxDay: ["CRASH_EMAILS_MAX_DAY", 20],
	d1MaxWritesDay: ["D1_MAX_WRITES_DAY", 80_000],
};

/** Metrics, diagnostics and events stop at this percent of a cap; reports may use the rest. */
export const LOW_PRIORITY_PERCENT = 90;

/** At most this many payloads per install per UTC day (guards against a buggy app). */
export const PAYLOADS_PER_INSTALL_DAY = { metrics: 3, diagnostics: 20 } as const;

/**
 * Estimated D1 rows written per row inserted or deleted in events, payloads or reports: the row
 * plus one entry in each of its three indexes. Each `usage` counter written costs one more.
 */
export const WRITES_PER_ROW = 4;

export type Counter =
	| "storedBytes"
	| "monthPuts"
	| "dayPuts"
	| "dayBytes"
	| "dayEvents"
	| "dayEmails"
	| "dayCrashEmails"
	| "dayWrites";
/** Set once on a day when something was refused, for the daily alert. */
export type Flag = "events" | "d1" | "r2";
export type Deltas = Partial<Record<Counter, number>>;

const CAPS: Record<Counter, keyof Limits> = {
	storedBytes: "r2MaxBytes",
	monthPuts: "r2MaxPutsMonth",
	dayPuts: "r2MaxPutsDay",
	dayBytes: "r2MaxBytesDay",
	dayEvents: "eventsMaxDay",
	dayEmails: "reportEmailsMaxDay",
	dayCrashEmails: "crashEmailsMaxDay",
	dayWrites: "d1MaxWritesDay",
};

export function limitsFrom(env: Env): Limits {
	const vars = env as unknown as Record<string, unknown>;
	const limits = {} as Limits;
	for (const [field, [variable, fallback]] of Object.entries(LIMIT_VARS) as [keyof Limits, readonly [string, number]][]) {
		limits[field] = parseLimit(vars[variable]) ?? fallback;
	}
	return limits;
}

function parseLimit(value: unknown): number | undefined {
	const number = typeof value === "string" && /^\s*\d+\s*$/.test(value) ? Number(value) : value;
	return typeof number === "number" && Number.isSafeInteger(number) && number >= 0 ? number : undefined;
}

export function utcDay(date: Date): string {
	return date.toISOString().slice(0, 10);
}

export function usageKeys(date: Date): Record<Counter, string> {
	const day = utcDay(date);
	return {
		storedBytes: "r2.bytes",
		monthPuts: `r2.puts.${day.slice(0, 7)}`,
		dayPuts: `r2.puts.${day}`,
		dayBytes: `r2.bytes.${day}`,
		dayEvents: `events.${day}`,
		dayEmails: `emails.${day}`,
		dayCrashEmails: `crashmail.${day}`,
		dayWrites: `d1.writes.${day}`,
	};
}

export function flagKeys(date: Date): Record<Flag, string> {
	const day = utcDay(date);
	return { events: `events.full.${day}`, d1: `d1.full.${day}`, r2: `r2.full.${day}` };
}

/** The R2 counters charged by storing one object of `bytes`. */
export function r2Put(bytes: number): Deltas {
	return { storedBytes: bytes, monthPuts: 1, dayPuts: 1, dayBytes: bytes };
}

/** `deltas` plus the D1 rows they cost: `rowWrites` and one per counter written (including dayWrites). */
export function withWrites(deltas: Deltas, rowWrites: number): Deltas {
	const counters = new Set([...Object.keys(deltas), "dayWrites"]);
	return { ...deltas, dayWrites: (deltas.dayWrites ?? 0) + rowWrites + counters.size };
}

/** Today's counters, read in one query, and the statements that update them. */
export class Budget {
	readonly keys: Record<Counter, string>;
	readonly flagKeys: Record<Flag, string>;
	private readonly values = new Map<string, number>();

	constructor(
		readonly limits: Limits,
		readonly now: Date,
	) {
		this.keys = usageKeys(now);
		this.flagKeys = flagKeys(now);
	}

	static async load(env: Env, now = new Date()): Promise<Budget> {
		const budget = new Budget(limitsFrom(env), now);
		return budget.load(await budget.read(env.DB).all<UsageRow>());
	}

	/** One statement reading every counter and flag of today. Pass its result to `load`. */
	read(db: D1Database): D1PreparedStatement {
		return readUsage(db, [...Object.values(this.keys), ...Object.values(this.flagKeys)]);
	}

	load(result: D1Result<unknown>): this {
		for (const row of result.results as UsageRow[]) this.values.set(row.key, row.value);
		return this;
	}

	value(counter: Counter): number {
		return this.values.get(this.keys[counter]) ?? 0;
	}

	cap(counter: Counter): number {
		return this.limits[CAPS[counter]];
	}

	/** True if adding every delta keeps its counter within `percent` of the cap. */
	allows(deltas: Deltas, percent = 100): boolean {
		return (Object.entries(deltas) as [Counter, number][]).every(
			([counter, delta]) => (this.value(counter) + delta) * 100 <= this.cap(counter) * percent,
		);
	}

	/** One upsert adding the deltas to today's counters. */
	add(db: D1Database, deltas: Deltas): D1PreparedStatement {
		return addUsage(
			db,
			(Object.entries(deltas) as [Counter, number][]).map(([counter, delta]) => [this.keys[counter], delta]),
		);
	}

	/** Records that something was refused today (at most one write per flag and day). */
	async markRefused(db: D1Database, flags: readonly Flag[]): Promise<void> {
		const statements = this.flag(db, flags);
		if (statements.length > 0) await db.batch(statements);
	}

	/** Statements marking that something was refused today; none for flags already set. */
	flag(db: D1Database, flags: readonly Flag[]): D1PreparedStatement[] {
		return flags
			.filter((flag) => !this.values.has(this.flagKeys[flag]))
			.map((flag) => {
				this.values.set(this.flagKeys[flag], 1);
				return db.prepare("INSERT OR IGNORE INTO usage (key, value) VALUES (?1, 1)").bind(this.flagKeys[flag]);
			});
	}
}

export interface UsageRow {
	key: string;
	value: number;
}

export function readUsage(db: D1Database, keys: readonly string[]): D1PreparedStatement {
	const placeholders = keys.map((_, index) => `?${index + 1}`).join(", ");
	return db.prepare(`SELECT key, value FROM usage WHERE key IN (${placeholders})`).bind(...keys);
}

export function addUsage(db: D1Database, entries: readonly (readonly [key: string, delta: number])[]): D1PreparedStatement {
	const values = entries.map((_, index) => `(?${2 * index + 1}, ?${2 * index + 2})`).join(", ");
	return db
		.prepare(`INSERT INTO usage (key, value) VALUES ${values} ON CONFLICT(key) DO UPDATE SET value = value + excluded.value`)
		.bind(...entries.flat());
}

/** Lowers `r2.bytes` after R2 objects were deleted, never below 0. */
export function releaseStoredBytes(db: D1Database, bytes: number): D1PreparedStatement {
	return db.prepare("UPDATE usage SET value = max(0, value - ?1) WHERE key = 'r2.bytes'").bind(bytes);
}

/** 503 until the next UTC day, when the daily counters start over. */
export function busy(now: Date): HttpError {
	const nextDay = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
	return new HttpError(503, "busy", { "Retry-After": String(Math.ceil((nextDay - now.getTime()) / 1000)) });
}
