-- SPDX-License-Identifier: AGPL-3.0-only
-- Homespun telemetry schema, v1. Times are ISO 8601 UTC strings.

-- One row per analytics event. `props` is the validated JSON object of allowlisted properties.
CREATE TABLE events (
	id INTEGER PRIMARY KEY,
	install TEXT NOT NULL,
	time TEXT NOT NULL,
	received TEXT NOT NULL,
	name TEXT NOT NULL,
	props TEXT NOT NULL,
	app_version TEXT,
	build TEXT,
	channel TEXT,
	model TEXT,
	os TEXT,
	family TEXT
);
CREATE INDEX events_name_time ON events (name, time);
CREATE INDEX events_install ON events (install);
-- Used by the daily retention cleanup.
CREATE INDEX events_received ON events (received);

-- MetricKit payloads; the JSON lives in R2 at r2_key. `summary` is set for diagnostics.
CREATE TABLE payloads (
	id TEXT PRIMARY KEY,
	install TEXT NOT NULL,
	kind TEXT NOT NULL,
	received TEXT NOT NULL,
	app_version TEXT,
	build TEXT,
	channel TEXT,
	model TEXT,
	os TEXT,
	r2_key TEXT NOT NULL,
	summary TEXT
);
CREATE INDEX payloads_install ON payloads (install);
CREATE INDEX payloads_kind_received ON payloads (kind, received);

-- Bug reports; the full JSON (with diagnostics) lives in R2 at r2_key.
CREATE TABLE reports (
	id TEXT PRIMARY KEY,
	install TEXT,
	received TEXT NOT NULL,
	app_version TEXT,
	build TEXT,
	channel TEXT,
	model TEXT,
	os TEXT,
	email TEXT,
	message TEXT NOT NULL,
	r2_key TEXT NOT NULL,
	status TEXT NOT NULL DEFAULT 'new'
);
CREATE INDEX reports_install ON reports (install);
CREATE INDEX reports_received ON reports (received);
