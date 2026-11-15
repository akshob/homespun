// SPDX-License-Identifier: AGPL-3.0-only

import { EVENT_ALLOWLIST } from "./allowlist";
import { badRequest, isObject, json } from "./http";
import { onlyKeys, parseApp, parseDevice, parseInstall, parseTime, quoted } from "./validate";

export const MAX_EVENTS = 100;
const MAX_INTEGER = 1e12;
const PROP_STRING = /^[A-Za-z0-9._:-]*$/;
const MAX_PROP_STRING = 64;

const INSERT_EVENT = `INSERT INTO events
	(install, time, received, name, props, app_version, build, channel, model, os, family)
	VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`;

interface ParsedEvent {
	name: string;
	time: string;
	props: string;
}

/** POST /v1/events: validates the whole batch first, then stores one row per event. */
export async function handleEvents(body: Record<string, unknown>, env: Env): Promise<Response> {
	onlyKeys(body, ["install", "app", "device", "events"], "body");
	const install = parseInstall(body.install);
	const app = parseApp(body.app);
	const device = parseDevice(body.device);
	const events = body.events;
	if (!Array.isArray(events) || events.length < 1 || events.length > MAX_EVENTS) {
		badRequest(`events: must be an array of 1 to ${MAX_EVENTS} events`);
	}
	const parsed = events.map((event, index) => parseEvent(event, `events[${index}]`));

	const received = new Date().toISOString();
	const insert = env.DB.prepare(INSERT_EVENT);
	await env.DB.batch(
		parsed.map((event) =>
			insert.bind(
				install,
				event.time,
				received,
				event.name,
				event.props,
				app.version,
				app.build,
				app.channel,
				device.model,
				device.os,
				device.family,
			),
		),
	);
	return json({ accepted: parsed.length }, 202);
}

function parseEvent(value: unknown, where: string): ParsedEvent {
	if (!isObject(value)) badRequest(`${where}: must be an object`);
	onlyKeys(value, ["name", "time", "props"], where);
	const name = value.name;
	if (typeof name !== "string") badRequest(`${where}.name: required`);
	if (!Object.hasOwn(EVENT_ALLOWLIST, name)) badRequest(`${where}.name: unknown event ${quoted(name)}`);
	const allowedKeys = EVENT_ALLOWLIST[name];
	const time = parseTime(value.time, `${where}.time`);
	const props = value.props ?? {};
	if (!isObject(props)) badRequest(`${where}.props: must be an object`);
	for (const [key, prop] of Object.entries(props)) {
		if (!allowedKeys.includes(key)) badRequest(`${where}.props: ${quoted(key)} is not allowed for ${quoted(name)}`);
		checkPropValue(prop, `${where}.props.${key}`);
	}
	return { name, time, props: JSON.stringify(props) };
}

function checkPropValue(value: unknown, where: string): void {
	switch (typeof value) {
		case "boolean":
			return;
		case "number":
			if (Number.isInteger(value) && Math.abs(value) <= MAX_INTEGER) return;
			badRequest(`${where}: numbers must be integers between -1e12 and 1e12`);
		case "string":
			if (value.length <= MAX_PROP_STRING && PROP_STRING.test(value)) return;
			badRequest(`${where}: strings must be at most ${MAX_PROP_STRING} characters of A-Z a-z 0-9 . _ : -`);
		default:
			badRequest(`${where}: must be an integer, a boolean or a short string`);
	}
}
