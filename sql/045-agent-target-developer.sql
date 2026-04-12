-- =============================================================================
-- 045: Intra-Project Agent-Messaging — target_developer_id
-- Spec #1964, Feature #1875
-- Requires: MariaDB 11.6+ (already required by sql/043 for VECTOR)
-- =============================================================================
--
-- Adds per-developer targeting to agent_messages:
--   target_developer_id = NULL → broadcast to all devs in project (backward-compat)
--   target_developer_id = set  → only target developer's sessions see the message
--
-- Idempotent via IF NOT EXISTS / IF EXISTS guards.
-- Normally executed once by Boot auto-migrate, guarded by ColumnExists check.

-- 1. Add column (ALGORITHM=INSTANT → no table rebuild, O(1))
ALTER TABLE `agent_messages`
  ADD COLUMN IF NOT EXISTS `target_developer_id` INT DEFAULT NULL
    AFTER `target_project_id`,
  ALGORITHM=INSTANT;

-- 2. Add foreign key (LOCK=NONE is NOT supported by MariaDB for
--    ON DELETE SET NULL — use default locking; agent_messages is small
--    enough that the brief metadata lock is acceptable).
ALTER TABLE `agent_messages`
  ADD CONSTRAINT IF NOT EXISTS `fk_am_target_dev`
    FOREIGN KEY (`target_developer_id`) REFERENCES `developers`(`id`)
    ON DELETE SET NULL;

-- 3. Replace idx_am_inbox with extended index (target_developer_id added).
--    Old: (target_project_id, status, created_at)
--    New: (target_project_id, target_developer_id, status, created_at)
--    Must be ONE atomic ALTER: fk_am_target_project depends on an index
--    with target_project_id as first column. MariaDB blocks a standalone
--    DROP because no other index would cover the FK. Combined DROP+ADD
--    is recognized as a replacement and allowed.
ALTER TABLE `agent_messages`
  DROP INDEX `idx_am_inbox`,
  ADD INDEX `idx_am_inbox`
    (`target_project_id`, `target_developer_id`, `status`, `created_at`);
