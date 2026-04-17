-- sql/046 — FR#2936/ADR-3264/Plan#3266 M1.8
-- User-Workspace ACL-Extension: add UI-Login-Flag to developers.
--
-- Scope: ONE column only — no type change on developer_project_access.access_level
-- (ADR-3264 Pivot: extend existing VARCHAR to accept 'comment' value without
-- schema change; 4-level hierarchy is enforced in application code via TAccessLevel
-- + IsAtLeast helpers in mx.Types.pas).
--
-- AFTER is_active per Plan#3266 M1.8 spec — places the flag next to the
-- existing authentication-relevant boolean for readability in admin UI.
--
-- Idempotent (IF NOT EXISTS, UPDATE is no-op when no rows match) — safe to re-run.

ALTER TABLE developers
  ADD COLUMN IF NOT EXISTS ui_login_enabled BOOLEAN NOT NULL DEFAULT TRUE
  AFTER is_active;

-- Migrate legacy access_level='write' -> 'read-write' per 4-level hierarchy.
-- Prevents user-lockout at first v2.4.0(96) boot: StringToAccessLevel in mx.Types.pas
-- does not recognise 'write' and would default-deny (alNone) any affected dev.
-- Idempotent: no-op if no 'write' rows exist. Issue caught by mxDesignChecker Pass 3.
UPDATE developer_project_access SET access_level = 'read-write' WHERE access_level = 'write';
