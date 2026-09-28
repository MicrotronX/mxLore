-- =============================================================================
-- sql/053 — client_keys device binding (Spec#17110, Plan#17121 M1)
-- =============================================================================
--
-- FR#17077 cycle 1. A client key can be bound softly to the device of the
-- proxy that uses it (header X-Device-Id), and the server records which proxy
-- version last used it (header X-Proxy-Version).
--
-- key_kind (VARCHAR, ENUM-free per sql/041):
--   * unbound — default; every existing key starts here.
--   * device  — bound to device_id on the first request that carries the
--               header (atomic UPDATE ... WHERE device_id IS NULL).
--   * cloud   — exempt from binding and min-version checks. Set by an admin
--               ONLY, never automatically: an automatic switch on "no header"
--               would let any client opt out by omitting the header, and would
--               turn every key of a pre-header proxy into cloud (design review
--               2026-09-28).
--
-- bound_at / bound_host: first-bind info for the admin (Req4).
-- last_seen_*: written per request; basis for the M2 gate "all non-cloud keys
-- seen on proxy >= N".
--
-- BACKWARD-COMPATIBLE: additive columns with defaults, no data change.
-- Idempotent: ADD COLUMN IF NOT EXISTS per column; the boot auto-migrate
-- (mx.Server.Boot.pas) checks the last column as sentinel.
-- -----------------------------------------------------------------------------

ALTER TABLE `client_keys`
  ADD COLUMN IF NOT EXISTS `key_kind` VARCHAR(16) NOT NULL DEFAULT 'unbound' AFTER `is_active`,
  ADD COLUMN IF NOT EXISTS `device_id` VARCHAR(64) DEFAULT NULL AFTER `key_kind`,
  ADD COLUMN IF NOT EXISTS `bound_at` DATETIME DEFAULT NULL AFTER `device_id`,
  ADD COLUMN IF NOT EXISTS `bound_host` VARCHAR(255) DEFAULT NULL AFTER `bound_at`,
  ADD COLUMN IF NOT EXISTS `last_seen_device_id` VARCHAR(64) DEFAULT NULL AFTER `bound_host`,
  ADD COLUMN IF NOT EXISTS `last_seen_proxy_version` VARCHAR(32) DEFAULT NULL AFTER `last_seen_device_id`;
