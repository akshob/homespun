-- SPDX-License-Identifier: AGPL-3.0-only
-- An install UUID is a consent generation. Never resurrect an erased generation.
-- Tombstones retain only a domain-separated SHA-256 digest, permanently.
-- No raw UUID, timestamp, or link to any other identity is retained here.
CREATE TABLE erased_installs (
	digest TEXT PRIMARY KEY NOT NULL CHECK (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*')
);

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

-- The Worker derives the digest before constructing statements and inserts a check
-- inside each admission/publication batch. A refusal rolls back the entire D1 batch,
-- including its budget charge. The AFTER trigger discards the check immediately:
-- no digest copies or raw UUIDs need to be added to existing content tables.
CREATE TABLE erasure_checks (digest TEXT NOT NULL);
CREATE TRIGGER erasure_check BEFORE INSERT ON erasure_checks
WHEN EXISTS (SELECT 1 FROM erased_installs WHERE digest = NEW.digest)
BEGIN SELECT RAISE(ABORT, 'homespun_erased_install'); END;
CREATE TRIGGER erasure_check_clear AFTER INSERT ON erasure_checks
BEGIN DELETE FROM erasure_checks WHERE rowid = NEW.rowid; END;
