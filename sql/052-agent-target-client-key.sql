-- =============================================================================
-- sql/052 — agent_messages.target_client_key_id
-- =============================================================================
--
-- Root-cause fix for BR#13641 (the ack trap). Two Claude instances of the SAME
-- developer working in the SAME project — e.g. a Mac and a Windows machine,
-- both authenticated as one developer account with different API keys — share
-- ONE mailbox. Until now a message could only be addressed to a PROJECT
-- (target_project_id) and optionally to a DEVELOPER (target_developer_id,
-- sql/045). Neither distinguishes the two instances, so addressing was left to
-- a convention in the payload ("to":"mac" / "to":"windows") that the server
-- could not see, let alone enforce.
--
-- Two consequences, both observed live on 2026-08-19:
--   * Every instance saw every message, including those meant for the other.
--   * mx_agent_ack could quit a message addressed to the other instance, which
--     then never received it. The only safeguard was a discipline rule
--     ("only ack what carries to == my role") — a convention against data
--     loss, not a technical one.
--
-- sql/050 already carries the SENDER's key identity. This migration adds the
-- symmetric receiver side, so the inbox filter and the ack path can compare at
-- the same key granularity the messaging design (Spec#1964) already uses.
--
-- BACKWARD-COMPATIBLE:
--   * Additive column, DEFAULT NULL, ALGORITHM=INSTANT (no table rebuild).
--   * NULL means "addressed to every instance" (broadcast) — exactly the
--     current behaviour. All existing rows therefore keep flowing unchanged,
--     and a sender that does not specify a target instance keeps broadcasting.
--   * FK ON DELETE SET NULL covers the rare hard-delete path only.
--     ⚡ It does NOT cover revoke or rotation: both flip `is_active = FALSE` and
--     leave the row in place, and rotation additionally inserts a NEW key (new
--     id, SAME name). ON DELETE never fires for either. A message addressed to
--     a rotated-away key would therefore match no live instance ever again —
--     invisible and unackable, which is the very silent loss this migration
--     exists to end. The read and ack paths close that hole in code: both treat
--     "target key no longer active" as a broadcast (the dead-key leg in
--     BuildInboxSql / AckAgentMessages). Schema and code together, not the FK
--     alone, produce the intended degradation.
--
-- Idempotent: IF NOT EXISTS guards allow safe re-run + partial-migration
-- recovery (column / FK applied independently, matching sql/045, 048, 050).
-- -----------------------------------------------------------------------------

-- 1. Add column (ALGORITHM=INSTANT -> O(1), no rebuild)
ALTER TABLE `agent_messages`
  ADD COLUMN IF NOT EXISTS `target_client_key_id` INT DEFAULT NULL
    AFTER `target_developer_id`;

-- 2. Add foreign key (ON DELETE SET NULL — a hard-deleted key must not take the
--    message history with it. Revoke/rotation do not delete, so the code-side
--    dead-key rule above is what covers them). FK has no IF NOT EXISTS in older
--    MariaDB; the boot auto-migrate guards it via
--    information_schema.table_constraints.
ALTER TABLE `agent_messages`
  ADD CONSTRAINT IF NOT EXISTS `fk_am_target_key`
    FOREIGN KEY (`target_client_key_id`) REFERENCES `client_keys`(`id`)
    ON DELETE SET NULL;
