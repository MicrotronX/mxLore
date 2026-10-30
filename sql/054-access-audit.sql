-- =============================================================================
-- sql/054 — access_audit: log of project access changes (Spec#19960, Plan#19964 M1)
-- =============================================================================
--
-- One row per change of developer_project_access (grant/change/revoke), and in
-- later milestones per private_on/private_off/owner_change/break_glass/denied.
-- Written only by mx.Logic.AccessWrite.pas in the same transaction as the
-- change itself.
--
-- Append-only: no API updates or deletes rows. Retention unlimited (User,
-- 2026-10-30). No foreign keys on purpose: the history must survive a hard
-- delete of the developer or project it names.
--
-- actor_developer_id NULL = no developer (boot, setup mode, server CLI); the
-- path is in `source`. action is VARCHAR (ENUM-free per sql/041).
--
-- Idempotent: CREATE TABLE IF NOT EXISTS; the boot auto-migrate
-- (mx.Server.Boot.pas) checks for the table.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `access_audit` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `created_at_utc` datetime(3) NOT NULL,
  `actor_developer_id` int(11) DEFAULT NULL,
  `project_id` int(11) NOT NULL,
  `target_developer_id` int(11) DEFAULT NULL,
  `action` varchar(20) NOT NULL,
  `level_before` varchar(30) NOT NULL DEFAULT '',
  `level_after` varchar(30) NOT NULL DEFAULT '',
  `source` varchar(50) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `idx_audit_project` (`project_id`, `created_at_utc`),
  KEY `idx_audit_target` (`target_developer_id`, `created_at_utc`),
  KEY `idx_audit_actor` (`actor_developer_id`, `created_at_utc`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
