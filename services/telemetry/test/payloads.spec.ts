// SPDX-License-Identifier: AGPL-3.0-only

import { describe, expect, it } from "vitest";
import { summarizeDiagnostics } from "../src/payloads";
import diagnosticPayload from "./fixtures/diagnostic-payload.json";
import metricPayload from "./fixtures/metric-payload.json";
import { APP, DEVICE, newInstall, objectText, post, rows } from "./helpers";

interface PayloadRow {
	id: string;
	install: string;
	kind: string;
	received: string;
	app_version: string;
	build: string;
	channel: string;
	model: string;
	os: string;
	r2_key: string;
	summary: string | null;
}

async function upload(kind: "metrics" | "diagnostics", payload: unknown, install = newInstall()) {
	const body = JSON.stringify({ install, app: APP, device: DEVICE, payload });
	const response = await post(`/v1/${kind}`, undefined, { body });
	return { response, install, body };
}

describe("POST /v1/metrics", () => {
	it("stores the JSON in R2 and a payloads row", async () => {
		const { response, install, body } = await upload("metrics", metricPayload);
		expect(response.status).toBe(202);
		expect(await response.json()).toEqual({ accepted: 1 });

		const [row, ...others] = await rows<PayloadRow>("SELECT * FROM payloads WHERE install = ?1", install);
		expect(others).toHaveLength(0);
		expect(row).toMatchObject({ kind: "metrics", app_version: "1.0", build: "42", channel: "testflight", model: "iPhone18,1", os: "27.2", summary: null });
		const day = row.received.slice(0, 10).replaceAll("-", "/");
		expect(row.r2_key).toBe(`metrics/${day}/${install}/${row.id}.json`);
		expect(await objectText(row.r2_key)).toBe(body);
	});

	it("rejects a missing or non-object payload", async () => {
		const install = newInstall();
		for (const payload of [undefined, null, [metricPayload], "text"]) {
			const response = await post("/v1/metrics", { install, app: APP, device: DEVICE, payload });
			expect(response.status).toBe(400);
			expect((await response.json<{ error: string }>()).error).toMatch(/^payload: /);
		}
		expect(await rows("SELECT id FROM payloads WHERE install = ?1", install)).toHaveLength(0);
	});

	it("rejects unknown fields", async () => {
		const response = await post("/v1/metrics", { install: newInstall(), app: APP, device: DEVICE, payload: {}, photos: [] });
		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: 'body: unknown field "photos"' });
	});
});

describe("POST /v1/diagnostics", () => {
	it("stores the JSON in R2 and a payloads row with a summary", async () => {
		const { response, install, body } = await upload("diagnostics", diagnosticPayload);
		expect(response.status).toBe(202);

		const [row] = await rows<PayloadRow>("SELECT * FROM payloads WHERE install = ?1", install);
		expect(row.kind).toBe("diagnostics");
		expect(row.r2_key).toMatch(new RegExp(`^diagnostics/\\d{4}/\\d{2}/\\d{2}/${install}/${row.id}\\.json$`));
		expect(await objectText(row.r2_key)).toBe(body);
		expect(JSON.parse(row.summary!)).toEqual({
			crashDiagnostics: 1,
			hangDiagnostics: 0,
			cpuExceptionDiagnostics: 0,
			diskWriteExceptionDiagnostics: 0,
			appLaunchDiagnostics: 0,
			firstCrash: {
				exceptionType: 1,
				signal: 11,
				terminationReason: "Namespace SIGNAL, Code 11 Segmentation fault: 11",
				appVersion: "1.0",
			},
		});
	});

	it("summarizes payloads with missing or odd keys", async () => {
		const zero = {
			crashDiagnostics: 0,
			hangDiagnostics: 0,
			cpuExceptionDiagnostics: 0,
			diskWriteExceptionDiagnostics: 0,
			appLaunchDiagnostics: 0,
		};
		expect(summarizeDiagnostics({})).toEqual(zero);
		expect(summarizeDiagnostics({ crashDiagnostics: "none", hangDiagnostics: [{}, {}], appLaunchDiagnostics: [{}] })).toEqual({
			...zero,
			hangDiagnostics: 2,
			appLaunchDiagnostics: 1,
		});
		expect(summarizeDiagnostics({ crashDiagnostics: [{ diagnosticMetaData: { signal: 6, exceptionType: null } }, {}] })).toEqual({
			...zero,
			crashDiagnostics: 2,
			firstCrash: { signal: 6 },
		});
		expect(summarizeDiagnostics({ crashDiagnostics: [null] })).toEqual({ ...zero, crashDiagnostics: 1 });

		const { response, install } = await upload("diagnostics", { timeStampBegin: "2026-11-14 00:00:00" });
		expect(response.status).toBe(202);
		const [row] = await rows<PayloadRow>("SELECT summary FROM payloads WHERE install = ?1", install);
		expect(JSON.parse(row.summary!)).toEqual(zero);
	});
});
