-- =============================================================================
-- sql/050 — agent_messages.sender_client_key_id
-- =============================================================================
--
-- Root-cause fix for cross-client-key intra-project messaging (Bug: two API
-- keys of the SAME developer in the SAME project — e.g. "Claude Code" and
-- "ChatGPT" both under one developer account — could not message each other
-- because the inbox self-echo guard compared at developer+project granularity
-- and classified the traffic as self-talk, silently filtering it out).
--
-- The intra-project messaging design (Spec#1964, GetSessionIdByKey) already
-- distinguishes agents by client_key. This migration carries that identity
-- into agent_messages so the self-echo guard can compare at KEY granularity.
--
-- BACKWARD-COMPATIBLE:
--   * Additive column, DEFAULT NULL, ALGORITHM=INSTANT (no table rebuild).
--   * Existing rows get NULL. The self-echo guard's NULL-guard means NULL-key
--     (legacy) messages are NEVER suppressed -> old pending messages flow
--     exactly as before.
--   * FK ON DELETE SET NULL: revoking/deleting a key does not orphan history.
--
-- Idempotent: IF NOT EXISTS guards allow safe re-run + partial-migration
-- recovery (column / FK applied independently, matching sql/045 + sql/048).
-- -----------------------------------------------------------------------------

-- 1. Add column (ALGORITHM=INSTANT -> O(1), no rebuild)
ALTER TABLE `agent_messages`
  ADD COLUMN IF NOT EXISTS `sender_client_key_id` INT DEFAULT NULL
    AFTER `sender_developer_id`;

-- 2. Add foreign key (ON DELETE SET NULL — preserve message history when a key
--    is revoked/deleted). FK has no IF NOT EXISTS in MariaDB; the boot
--    auto-migrate guards it via information_schema.table_constraints.
ALTER TABLE `agent_messages`
  ADD CONSTRAINT IF NOT EXISTS `fk_am_sender_key`
    FOREIGN KEY (`sender_client_key_id`) REFERENCES `client_keys`(`id`)
    ON DELETE SET NULL;
