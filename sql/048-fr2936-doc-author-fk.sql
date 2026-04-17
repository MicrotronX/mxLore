-- sql/048 — FR#2936/Plan#3266 M2.5 prerequisite — documents.created_by_developer_id
--
-- Adds a real FK from documents.created_by_developer_id to developers.id.
-- The legacy created_by VARCHAR(100) column stays for display/back-compat
-- (typical values: 'mcp', 'admin', dev-name, 'migration') but is unsuitable
-- for the M2.5 Edit-Window author-match (60min/24h gate) because two devs
-- can share the same display name, and 'mcp'/'migration' map to no dev at all.
--
-- M2.5 mx_update_note + future caller-attribution work compares the request
-- caller's developer_id against this FK column for unambiguous identity.
--
-- ALTER TABLE — ADD COLUMN + KEY + FK ON DELETE SET NULL
-- (SET NULL preserves the historical authorship label in created_by even
--  if the developer row is later removed.)
--
-- NO BACKFILL: legacy created_by VARCHAR is free-form caller-supplied label,
-- not authenticated identity — name-matching against developers.name or
-- client_keys.name produces unreliable / false-positive assignments. Old
-- docs stay created_by_developer_id IS NULL by design. Going-forward only.
-- See FR#3307 (deprecate created_by VARCHAR phase-out).
--
-- Idempotent (IF NOT EXISTS) — safe to re-run.

ALTER TABLE documents
  ADD COLUMN IF NOT EXISTS created_by_developer_id INT NULL AFTER created_by;

ALTER TABLE documents
  ADD KEY IF NOT EXISTS idx_doc_created_by_dev (created_by_developer_id);

-- FK: ON DELETE SET NULL — keep the historical authorship row, just clear
-- the link if the developer is hard-deleted. (developers.is_active is the
-- typical retirement path; hard-delete is rare.)
ALTER TABLE documents
  ADD CONSTRAINT fk_doc_created_by_dev
    FOREIGN KEY (created_by_developer_id) REFERENCES developers(id)
    ON DELETE SET NULL;
