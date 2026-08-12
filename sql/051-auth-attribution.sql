-- =============================================================================
-- sql/051 — Auth-Attribution (Spec#13053, gh#10)
-- =============================================================================
--
-- Server-side identity stamping: documents and doc_revisions carry the
-- authenticated identity pair (developer_id, client_key_id) instead of only
-- the free-form, caller-supplied created_by/changed_by VARCHAR label.
--
--   * documents.created_by_developer_id already exists (sql/048).
--   * This migration adds the missing three columns:
--       documents.created_by_client_key_id      -> which machine/key created
--       doc_revisions.changed_by_developer_id   -> which developer changed
--       doc_revisions.changed_by_client_key_id  -> which machine/key changed
--
-- Machine granularity follows the "one API key per machine" convention
-- (client_keys.name = machine label) — same identity model as
-- agent_messages.sender_client_key_id (sql/050).
--
-- BACKWARD-COMPATIBLE:
--   * Additive columns, DEFAULT NULL, no table rebuild required.
--   * NO BACKFILL (same rationale as sql/048): legacy label strings are not
--     authenticated identity; name-matching would create false attributions.
--   * FK ON DELETE SET NULL: deleting a developer or revoking a key keeps
--     the historical rows, only the link is cleared.
--
-- Idempotent: IF NOT EXISTS guards (MariaDB supports them for columns, keys
-- AND constraints); column / index / FK applied independently
-- (partial-migration recovery, matching sql/048 + sql/050). The boot
-- auto-migrate additionally guards FKs via information_schema.table_constraints.
-- -----------------------------------------------------------------------------

-- 1. documents.created_by_client_key_id
ALTER TABLE `documents`
  ADD COLUMN IF NOT EXISTS `created_by_client_key_id` INT DEFAULT NULL
    AFTER `created_by_developer_id`;

ALTER TABLE `documents`
  ADD KEY IF NOT EXISTS `idx_doc_created_by_key` (`created_by_client_key_id`);

ALTER TABLE `documents`
  ADD CONSTRAINT IF NOT EXISTS `fk_doc_created_by_key`
    FOREIGN KEY (`created_by_client_key_id`) REFERENCES `client_keys`(`id`)
    ON DELETE SET NULL;

-- 2. doc_revisions.changed_by_developer_id
ALTER TABLE `doc_revisions`
  ADD COLUMN IF NOT EXISTS `changed_by_developer_id` INT DEFAULT NULL
    AFTER `changed_by`;

ALTER TABLE `doc_revisions`
  ADD KEY IF NOT EXISTS `idx_rev_changed_by_dev` (`changed_by_developer_id`);

ALTER TABLE `doc_revisions`
  ADD CONSTRAINT IF NOT EXISTS `fk_rev_changed_by_dev`
    FOREIGN KEY (`changed_by_developer_id`) REFERENCES `developers`(`id`)
    ON DELETE SET NULL;

-- 3. doc_revisions.changed_by_client_key_id
ALTER TABLE `doc_revisions`
  ADD COLUMN IF NOT EXISTS `changed_by_client_key_id` INT DEFAULT NULL
    AFTER `changed_by_developer_id`;

ALTER TABLE `doc_revisions`
  ADD KEY IF NOT EXISTS `idx_rev_changed_by_key` (`changed_by_client_key_id`);

ALTER TABLE `doc_revisions`
  ADD CONSTRAINT IF NOT EXISTS `fk_rev_changed_by_key`
    FOREIGN KEY (`changed_by_client_key_id`) REFERENCES `client_keys`(`id`)
    ON DELETE SET NULL;
