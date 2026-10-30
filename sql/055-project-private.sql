-- =============================================================================
-- sql/055 — projects.is_private (Spec#19960, Plan#19964 M2.1)
-- =============================================================================
--
-- 1 = the admin bypass does not apply to this project; access only for the
-- owner (created_by_developer_id) or a developer_project_access row.
--
-- Own column on purpose: fk_projects_created_by is ON DELETE SET NULL, so a
-- deleted owner leaves is_private=1 with owner NULL. That state stays locked
-- and is only recoverable through the server CLI, it never turns public.

ALTER TABLE projects
  ADD COLUMN IF NOT EXISTS is_private TINYINT(1) NOT NULL DEFAULT 0
  AFTER is_active;
