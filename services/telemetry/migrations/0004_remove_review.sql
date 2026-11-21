-- SPDX-License-Identifier: AGPL-3.0-only
-- Retire the former download gate's counters without changing telemetry data or R2 objects.
DROP TABLE IF EXISTS demo_lockouts;
