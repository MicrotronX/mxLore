-- sql/049 — FR#2936/Plan#3266 M3 schema foundation
--
-- Adds the columns required by M3 Bundles 1+2+3+4:
--   * developers.accept_agent_messages       (M3.2 opt-out flag for inbox notifications)
--   * client_keys.revoked_at / revoked_by    (M3.6 revocation timestamp + actor)
--   * client_keys.revoked_reason             (M3.6 short rationale, audit trail)
--   * client_keys.revoke_ip                  (M3.7 forensik IP)
--   * client_keys.revoke_user_agent          (M3.7 forensik UA)
--   * client_keys.revoke_actor_type          (M3.7 admin/self/system label)
--   * client_keys.last_warned_stage          (M3.4 warning-cadence dedupe)
--   * tool_call_log.auth_reason              (M3.11 namespaced auth-reason for RFC7807 errors)
--
-- Plus a partial UNIQUE index on (key_prefix) WHERE revoked_at IS NULL
-- to harden Bug#3199 prefix-collision-on-revocation (M3.8 belt+suspenders).
--
-- expires_at semantics evolution (M3.3): the column already exists nullable.
-- This migration leaves the schema as-is (still NULL=never-expires) but the
-- application layer in mx.Auth.Expiry will start populating new keys with
-- role-dependent defaults (admin=180d, user=90d, reviewer=30d). Existing
-- NULL keys are NOT backfilled here — handled by an opt-in admin tool to
-- avoid surprise lockouts. See FR#3307-style decision pattern.
--
-- Idempotent (IF NOT EXISTS / WHERE-clauses) — safe to re-run.

ALTER TABLE developers
  ADD COLUMN IF NOT EXISTS accept_agent_messages TINYINT(1) NOT NULL DEFAULT 1
    AFTER ui_login_enabled;

ALTER TABLE client_keys
  ADD COLUMN IF NOT EXISTS revoked_at DATETIME NULL AFTER expires_at,
  ADD COLUMN IF NOT EXISTS revoked_by INT NULL AFTER revoked_at,
  ADD COLUMN IF NOT EXISTS revoked_reason VARCHAR(255) NULL AFTER revoked_by,
  ADD COLUMN IF NOT EXISTS revoke_ip VARCHAR(45) NULL AFTER revoked_reason,
  ADD COLUMN IF NOT EXISTS revoke_user_agent VARCHAR(255) NULL AFTER revoke_ip,
  ADD COLUMN IF NOT EXISTS revoke_actor_type VARCHAR(20) NULL AFTER revoke_user_agent,
  ADD COLUMN IF NOT EXISTS last_warned_stage VARCHAR(8) NULL AFTER revoke_actor_type;

-- FK: revoked_by -> developers.id ON DELETE SET NULL (preserve audit row even
-- if the actor account is later removed).
ALTER TABLE client_keys
  ADD CONSTRAINT fk_client_keys_revoked_by
    FOREIGN KEY (revoked_by) REFERENCES developers(id) ON DELETE SET NULL;

-- M3.8 Bug#3199 belt+suspenders: ensure no two ACTIVE (un-revoked) keys can
-- ever share the same prefix. The wider UNIQUE on key_hash already exists,
-- but key_prefix is the lookup-shortcut — a prefix collision between an
-- active and a revoked key would let the lookup match the wrong row before
-- the application AND-clause filters revoked_at IS NULL.
-- MariaDB 10.5+ supports filtered/conditional uniqueness via virtual cols;
-- the simplest portable approach is a partial-unique index on a virtual
-- column that is NULL when revoked, NON-NULL when active.
ALTER TABLE client_keys
  ADD COLUMN IF NOT EXISTS active_prefix VARCHAR(12)
    AS (IF(revoked_at IS NULL, key_prefix, NULL)) VIRTUAL;

ALTER TABLE client_keys
  ADD UNIQUE KEY IF NOT EXISTS uq_active_key_prefix (active_prefix);

ALTER TABLE tool_call_log
  ADD COLUMN IF NOT EXISTS auth_reason VARCHAR(32) NULL
    COMMENT 'M3.11 RFC7807 reason-code (e.g. expired, revoked, db_check_degraded)';
