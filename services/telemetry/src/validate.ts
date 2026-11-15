// SPDX-License-Identifier: AGPL-3.0-only

import { badRequest, isObject } from "./http";

export const CHANNELS = ["debug", "testflight", "appstore"] as const;
export const FAMILIES = ["iphone", "duo"] as const;

const INSTALL_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

export interface AppInfo {
	version: string;
	build: string;
	channel: (typeof CHANNELS)[number];
}

export interface DeviceInfo {
	model: string;
	os: string;
	family: (typeof FAMILIES)[number];
}

/** A user-supplied value, shortened and quoted for an error message. */
export function quoted(value: string): string {
	return JSON.stringify(value.length > 40 ? `${value.slice(0, 40)}…` : value);
}

export function onlyKeys(object: Record<string, unknown>, allowed: readonly string[], where: string): void {
	for (const key of Object.keys(object)) {
		if (!allowed.includes(key)) badRequest(`${where}: unknown field ${quoted(key)}`);
	}
}

export function shortString(value: unknown, max: number, where: string): string {
	if (value === undefined || value === null) badRequest(`${where}: required`);
	if (typeof value !== "string") badRequest(`${where}: must be a string`);
	if (value.length > max) badRequest(`${where}: longer than ${max} characters`);
	if (CONTROL_CHARACTERS.test(value)) badRequest(`${where}: contains control characters`);
	return value;
}

export function oneOf<T extends string>(value: unknown, options: readonly T[], where: string): T {
	if (typeof value !== "string" || !(options as readonly string[]).includes(value)) {
		badRequest(`${where}: must be one of ${options.join(", ")}`);
	}
	return value as T;
}

export function isInstall(value: unknown): value is string {
	return typeof value === "string" && INSTALL_PATTERN.test(value);
}

export function parseInstall(value: unknown, where = "install"): string {
	if (value === undefined || value === null) badRequest(`${where}: required`);
	if (!isInstall(value)) badRequest(`${where}: must be a lowercase UUID`);
	return value;
}

export function parseApp(value: unknown): AppInfo {
	if (value === undefined || value === null) badRequest("app: required");
	if (!isObject(value)) badRequest("app: must be an object");
	onlyKeys(value, ["version", "build", "channel"], "app");
	return {
		version: shortString(value.version, 16, "app.version"),
		build: shortString(value.build, 16, "app.build"),
		channel: oneOf(value.channel, CHANNELS, "app.channel"),
	};
}

export function parseDevice(value: unknown): DeviceInfo {
	if (value === undefined || value === null) badRequest("device: required");
	if (!isObject(value)) badRequest("device: must be an object");
	onlyKeys(value, ["model", "os", "family"], "device");
	return {
		model: shortString(value.model, 32, "device.model"),
		os: shortString(value.os, 16, "device.os"),
		family: oneOf(value.family, FAMILIES, "device.family"),
	};
}

const ISO_DATE_TIME = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:?\d{2})$/;

/** Parses an ISO 8601 date-time with a zone ("2026-11-15T21:40:00Z") and returns it in UTC. */
export function parseTime(value: unknown, where: string): string {
	const match = typeof value === "string" ? ISO_DATE_TIME.exec(value) : null;
	if (match === null) badRequest(`${where}: must be an ISO 8601 date-time with a zone`);
	const [, dateTime, fraction, zone] = match;
	const millis = fraction ? `${fraction}000`.slice(0, 4) : "";
	const offset = zone.length === 5 ? `${zone.slice(0, 3)}:${zone.slice(3)}` : zone;
	const time = Date.parse(`${dateTime}${millis}${offset}`);
	if (Number.isNaN(time)) badRequest(`${where}: must be an ISO 8601 date-time with a zone`);
	return new Date(time).toISOString();
}
