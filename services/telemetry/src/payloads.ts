// SPDX-License-Identifier: AGPL-3.0-only

import {
	Budget,
	limitsFrom,
	LOW_PRIORITY_PERCENT,
	PAYLOADS_PER_INSTALL_DAY,
	r2Put,
	utcDay,
	WRITES_PER_ROW,
	withWrites,
	type Flag,
} from "./budget";
import { badRequest, isObject, json, type JsonBody } from "./http";
import { onlyKeys, parseApp, parseDevice, parseInstall } from "./validate";

export type PayloadKind = "metrics" | "diagnostics";
export const PAYLOAD_KINDS: readonly PayloadKind[] = ["metrics", "diagnostics"];

/** `diagnosticMetaData` fields of the first crash copied into the summary. */
const CRASH_FIELDS = ["exceptionType", "signal", "terminationReason", "appVersion"] as const;

const INSERT_PAYLOAD = `INSERT INTO payloads
	(id, install, kind, received, app_version, build, channel, model, os, r2_key, summary, size)
	VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`;

/** Counts of the diagnostic arrays in an MXDiagnosticPayload JSON representation. */
export interface DiagnosticSummary {
	crashDiagnostics: number;
	hangDiagnostics: number;
	cpuExceptionDiagnostics: number;
	diskWriteExceptionDiagnostics: number;
	appLaunchDiagnostics: number;
	firstCrash?: Partial<Record<(typeof CRASH_FIELDS)[number], string | number>>;
}

/**
 * POST /v1/metrics and /v1/diagnostics: stores the request JSON verbatim in R2 at
 * `<kind>/YYYY/MM/DD/<install>/<id>.json` and indexes it in the `payloads` table.
 * Refused with 202 `{"accepted": 0, "reason": …}` past the per-install daily limit ("limit") or
 * 90% of an R2 or D1 budget ("budget"); the app does not retry these.
 */
export async function handlePayload(kind: PayloadKind, body: JsonBody, env: Env): Promise<Response> {
	const { value } = body;
	onlyKeys(value, ["install", "app", "device", "payload"], "body");
	const install = parseInstall(value.install);
	const app = parseApp(value.app);
	const device = parseDevice(value.device);
	if (value.payload === undefined || value.payload === null) badRequest("payload: required");
	if (!isObject(value.payload)) badRequest("payload: must be an object");
	const summary = kind === "diagnostics" ? JSON.stringify(summarizeDiagnostics(value.payload)) : null;

	const now = new Date();
	const budget = new Budget(limitsFrom(env), now);
	const [today, usage] = await env.DB.batch([
		env.DB.prepare("SELECT count(*) AS n FROM payloads WHERE install = ?1 AND kind = ?2 AND received >= ?3").bind(
			install,
			kind,
			`${utcDay(now)}T00:00:00.000Z`,
		),
		budget.read(env.DB),
	]);
	budget.load(usage);
	if ((today.results[0] as { n: number }).n >= PAYLOADS_PER_INSTALL_DAY[kind]) {
		return json({ accepted: 0, reason: "limit" }, 202);
	}
	const deltas = withWrites(r2Put(body.bytes), WRITES_PER_ROW);
	if (!budget.allows(deltas, LOW_PRIORITY_PERCENT)) {
		const refused: Flag[] = [];
		if (!budget.allows(r2Put(body.bytes), LOW_PRIORITY_PERCENT)) refused.push("r2");
		if (!budget.allows({ dayWrites: deltas.dayWrites }, LOW_PRIORITY_PERCENT)) refused.push("d1");
		await budget.markRefused(env.DB, refused);
		return json({ accepted: 0, reason: "budget" }, 202);
	}

	const id = crypto.randomUUID();
	const received = now.toISOString();
	const key = `${kind}/${utcDay(now).replaceAll("-", "/")}/${install}/${id}.json`;

	await env.BUCKET.put(key, body.text, { httpMetadata: { contentType: "application/json" } });
	try {
		await env.DB.batch([
			env.DB.prepare(INSERT_PAYLOAD).bind(
				id,
				install,
				kind,
				received,
				app.version,
				app.build,
				app.channel,
				device.model,
				device.os,
				key,
				summary,
				body.bytes,
			),
			budget.add(env.DB, deltas),
		]);
	} catch (error) {
		await env.BUCKET.delete(key).catch(() => {});
		throw error;
	}
	return json({ accepted: 1 }, 202);
}

/** Counts diagnostics by type and copies a few fields of the first crash. Tolerates missing keys. */
export function summarizeDiagnostics(payload: Record<string, unknown>): DiagnosticSummary {
	const count = (key: string) => {
		const list = payload[key];
		return Array.isArray(list) ? list.length : 0;
	};
	const summary: DiagnosticSummary = {
		crashDiagnostics: count("crashDiagnostics"),
		hangDiagnostics: count("hangDiagnostics"),
		cpuExceptionDiagnostics: count("cpuExceptionDiagnostics"),
		diskWriteExceptionDiagnostics: count("diskWriteExceptionDiagnostics"),
		appLaunchDiagnostics: count("appLaunchDiagnostics"),
	};
	const crashes = payload.crashDiagnostics;
	const first = Array.isArray(crashes) ? crashes[0] : undefined;
	const meta = isObject(first) ? first.diagnosticMetaData : undefined;
	if (isObject(meta)) {
		const firstCrash: NonNullable<DiagnosticSummary["firstCrash"]> = {};
		for (const field of CRASH_FIELDS) {
			const value = meta[field];
			if (typeof value === "number" && Number.isFinite(value)) firstCrash[field] = value;
			else if (typeof value === "string") firstCrash[field] = value.slice(0, 200);
		}
		if (Object.keys(firstCrash).length > 0) summary.firstCrash = firstCrash;
	}
	return summary;
}
