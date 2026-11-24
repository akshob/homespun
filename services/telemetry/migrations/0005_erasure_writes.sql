-- SPDX-License-Identifier: AGPL-3.0-only
-- An install UUID is a consent generation. Never resurrect an erased generation.
-- Tombstones are permanent, contain no timestamps or links to other identities.
CREATE TABLE erased_installs (install TEXT PRIMARY KEY NOT NULL);

-- Reserve/index every object BEFORE issuing its PUT. Only its writer can certify
-- that the PUT settled; a crashed writer's cleanup pointer must remain retryable.
CREATE TABLE object_writes (
	r2_key TEXT PRIMARY KEY NOT NULL,
	install TEXT,
	created TEXT NOT NULL,
	checked TEXT NOT NULL,
	size INTEGER NOT NULL,
	state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'cleanup')),
	settled INTEGER NOT NULL DEFAULT 0 CHECK (settled IN (0, 1))
);
CREATE INDEX object_writes_install ON object_writes (install);
CREATE INDEX object_writes_cleanup ON object_writes (state, checked);

-- These checks run in the same D1 transaction as admission and its budget charge,
-- not as a racy read before a suspension. Existing v1 rows/columns remain valid.
CREATE TRIGGER events_erasure BEFORE INSERT ON events
WHEN EXISTS (SELECT 1 FROM erased_installs WHERE install = NEW.install)
BEGIN SELECT RAISE(ABORT, 'homespun_erased_install'); END;
CREATE TRIGGER payloads_erasure BEFORE INSERT ON payloads
WHEN EXISTS (SELECT 1 FROM erased_installs WHERE install = NEW.install)
BEGIN SELECT RAISE(ABORT, 'homespun_erased_install'); END;
CREATE TRIGGER reports_erasure BEFORE INSERT ON reports
WHEN EXISTS (SELECT 1 FROM erased_installs WHERE install = NEW.install)
BEGIN SELECT RAISE(ABORT, 'homespun_erased_install'); END;
CREATE TRIGGER object_writes_erasure BEFORE INSERT ON object_writes
WHEN EXISTS (SELECT 1 FROM erased_installs WHERE install = NEW.install)
BEGIN SELECT RAISE(ABORT, 'homespun_erased_install'); END;
