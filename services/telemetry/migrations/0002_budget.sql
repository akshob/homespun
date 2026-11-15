-- SPDX-License-Identifier: AGPL-3.0-only
-- Usage budget: bytes kept in R2 per row, and usage counters (see src/budget.ts).

-- Bytes stored in R2 for the row; 0 when it has no R2 object.
ALTER TABLE payloads ADD COLUMN size INTEGER NOT NULL DEFAULT 0;
ALTER TABLE reports ADD COLUMN size INTEGER NOT NULL DEFAULT 0;

-- Counters such as `r2.bytes`, `r2.puts.2026-11`, `events.2026-11-15`, and alert markers.
-- WITHOUT ROWID: one row written per update instead of a row plus an index entry.
CREATE TABLE usage (key TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;
