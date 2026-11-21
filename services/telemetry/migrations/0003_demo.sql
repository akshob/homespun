-- SPDX-License-Identifier: AGPL-3.0-only
-- Only short-lived, keyed rate-limit counters: never the code, session token or raw IP.
CREATE TABLE demo_lockouts (
    key TEXT PRIMARY KEY,
    failures INTEGER NOT NULL,
    window_start INTEGER NOT NULL,
    locked_until INTEGER NOT NULL,
    expires INTEGER NOT NULL
);
