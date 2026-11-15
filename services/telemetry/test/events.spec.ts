// SPDX-License-Identifier: AGPL-3.0-only

import { describe, expect, it } from "vitest";
import { EVENT_ALLOWLIST } from "../src/allowlist";
import { APP, DEVICE, newInstall, post, rows } from "./helpers";

const TIME = "2026-11-15T21:40:00Z";

function batch(events: unknown[], install = newInstall()) {
	return { install, app: APP, device: DEVICE, events };
}

async function expectRejected(body: unknown, error: RegExp | string): Promise<void> {
	const response = await post("/v1/events", body);
	expect(response.status).toBe(400);
	const message = (await response.json<{ error: string }>()).error;
	if (typeof error === "string") expect(message).toBe(error);
	else expect(message).toMatch(error);
}

async function eventCount(install: string): Promise<number> {
	return (await rows<{ n: number }>("SELECT count(*) AS n FROM events WHERE install = ?1", install))[0].n;
}

describe("POST /v1/events", () => {
	it("accepts a valid batch and stores one row per event", async () => {
		const install = newInstall();
		const events = [
			{ name: "app.launch", time: TIME, props: { cold: true } },
			{ name: "analytics.optin", time: TIME, props: {} },
			{ name: "run.finished", time: "2026-11-15T21:41:07Z", props: { trigger: "background", items: 120, bytes: 3412, duration: 95, backedUp: 118, failed: 0, kept: 2, notYet: 0, compacted: 117 } },
			{ name: "freeup.finished", time: "2026-11-15T22:41:07+01:00", props: { items: 40, bytes: -1, first: false } },
			{ name: "error", time: "2026-11-15T21:42:00.250Z", props: { domain: "NSURLErrorDomain", code: -1009, where: "upload" } },
			{ name: "server.info", time: TIME, props: { kind: "docker", mode: "immich", version: "1.2.0-beta.3", arch: "x86_64" } },
		];
		const response = await post("/v1/events", batch(events, install));
		expect(response.status).toBe(202);
		expect(await response.json()).toEqual({ accepted: events.length });

		const stored = await rows("SELECT * FROM events WHERE install = ?1 ORDER BY id", install);
		expect(stored).toHaveLength(events.length);
		expect(stored[0]).toMatchObject({
			install,
			time: "2026-11-15T21:40:00.000Z",
			name: "app.launch",
			props: '{"cold":true}',
			app_version: "1.0",
			build: "42",
			channel: "testflight",
			model: "iPhone18,1",
			os: "27.2",
			family: "iphone",
		});
		expect(stored[1]).toMatchObject({ name: "analytics.optin", props: "{}" });
		expect(JSON.parse(stored[2].props as string)).toEqual(events[2].props);
		expect(stored[3].time).toBe("2026-11-15T21:41:07.000Z");
		expect(stored[4].time).toBe("2026-11-15T21:42:00.250Z");
		expect(Date.now() - Date.parse(stored[0].received as string)).toBeLessThan(60_000);
		expect(new Set(stored.map((row) => row.received)).size).toBe(1);
	});

	it("accepts every allowlisted event and a 100-event batch", async () => {
		const install = newInstall();
		const all = Object.keys(EVENT_ALLOWLIST).map((name) => ({ name, time: TIME, props: {} }));
		const events = Array.from({ length: 100 }, (_, i) => all[i % all.length]);
		const response = await post("/v1/events", batch(events, install));
		expect(response.status).toBe(202);
		expect(await response.json()).toEqual({ accepted: 100 });
		expect(await eventCount(install)).toBe(100);
	});

	it("accepts events without props", async () => {
		const response = await post("/v1/events", batch([{ name: "analytics.optin", time: TIME }]));
		expect(response.status).toBe(202);
	});

	it("rejects the whole batch for an unknown event name", async () => {
		const install = newInstall();
		const body = batch(
			[
				{ name: "app.launch", time: TIME, props: { cold: false } },
				{ name: "photo.viewed", time: TIME, props: {} },
			],
			install,
		);
		await expectRejected(body, 'events[1].name: unknown event "photo.viewed"');
		expect(await eventCount(install)).toBe(0);
	});

	it("rejects a prop key that is not allowed for the event", async () => {
		await expectRejected(
			batch([{ name: "setup.step", time: TIME, props: { step: "pair", fileName: "IMG_0001" } }]),
			'events[0].props: "fileName" is not allowed for "setup.step"',
		);
		await expectRejected(
			batch([{ name: "analytics.optin", time: TIME, props: { cold: true } }]),
			'events[0].props: "cold" is not allowed for "analytics.optin"',
		);
		await expectRejected(batch([{ name: "app.launch", time: TIME, props: { constructor: 1 } }]), /not allowed/);
		await expectRejected(batch([{ name: "toString", time: TIME, props: {} }]), /unknown event/);
	});

	it.each([
		["a fraction", 1.5, /integers/],
		["a huge integer", 1e12 + 1, /integers/],
		["a huge negative integer", -1e12 - 1, /integers/],
		["a string with spaces", "my server", /strings/],
		["a string with a slash", "/Users/me", /strings/],
		["an address", "192.168.1.10/24", /strings/],
		["a long string", "x".repeat(65), /strings/],
		["null", null, /must be an integer, a boolean or a short string/],
		["an object", { nested: 1 }, /must be an integer, a boolean or a short string/],
		["an array", [1], /must be an integer, a boolean or a short string/],
	])("rejects %s as a prop value", async (_, value, error) => {
		await expectRejected(batch([{ name: "freeup.finished", time: TIME, props: { items: value } }]), error);
	});

	it("accepts boundary prop values", async () => {
		const props = { items: 1e12, bytes: -1e12, first: true };
		expect((await post("/v1/events", batch([{ name: "freeup.finished", time: TIME, props }]))).status).toBe(202);
		const strings = { feature: "x".repeat(64), detail: "a.b_c:d-E9" };
		expect((await post("/v1/events", batch([{ name: "feature.used", time: TIME, props: strings }]))).status).toBe(202);
		expect((await post("/v1/events", batch([{ name: "feature.used", time: TIME, props: { feature: "" } }]))).status).toBe(202);
	});

	it("rejects too many or too few events", async () => {
		const events = Array.from({ length: 101 }, () => ({ name: "app.launch", time: TIME, props: {} }));
		await expectRejected(batch(events), "events: must be an array of 1 to 100 events");
		await expectRejected(batch([]), "events: must be an array of 1 to 100 events");
		await expectRejected({ install: newInstall(), app: APP, device: DEVICE }, "events: must be an array of 1 to 100 events");
	});

	it.each([
		["a missing time", { name: "app.launch", props: {} }, /events\[0\]\.time/],
		["a time without zone", { name: "app.launch", time: "2026-11-15T21:40:00", props: {} }, /events\[0\]\.time/],
		["a date only", { name: "app.launch", time: "2026-11-15", props: {} }, /events\[0\]\.time/],
		["an invalid month", { name: "app.launch", time: "2026-13-15T21:40:00Z", props: {} }, /events\[0\]\.time/],
		["a numeric time", { name: "app.launch", time: 1763242800, props: {} }, /events\[0\]\.time/],
		["props as an array", { name: "app.launch", time: TIME, props: [] }, /events\[0\]\.props: must be an object/],
		["an extra event field", { name: "app.launch", time: TIME, props: {}, user: "me" }, /unknown field "user"/],
		["a missing name", { time: TIME, props: {} }, /events\[0\]\.name: required/],
	])("rejects an event with %s", async (_, event, error) => {
		await expectRejected(batch([event]), error);
	});

	it.each([
		["an uppercase install", { install: "8A7E7C1C-6B7A-4A55-9D3E-0C1B2A3D4E5F" }, "install: must be a lowercase UUID"],
		["a missing install", { install: undefined }, "install: required"],
		["a bad channel", { app: { ...APP, channel: "beta" } }, "app.channel: must be one of debug, testflight, appstore"],
		["a long version", { app: { ...APP, version: "1.0.0.0.0.0.0.0.0" } }, "app.version: longer than 16 characters"],
		["a missing build", { app: { version: "1.0", channel: "debug" } }, "app.build: required"],
		["a bad family", { device: { ...DEVICE, family: "ipad" } }, "device.family: must be one of iphone, duo"],
		["a long model", { device: { ...DEVICE, model: "x".repeat(33) } }, "device.model: longer than 32 characters"],
		["an extra device field", { device: { ...DEVICE, name: "Jane's iPhone" } }, 'device: unknown field "name"'],
		["an extra top-level field", { server: "192.168.1.10" }, 'body: unknown field "server"'],
	])("rejects %s", async (_, change, error) => {
		await expectRejected({ ...batch([{ name: "app.launch", time: TIME, props: {} }]), ...change }, error);
	});
});
