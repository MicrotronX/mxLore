-- sql/047 — FR#2936/Plan#3266 M2.3 — Note-System Hybrid Parent-Relation DDL
--
-- Adds two columns to documents table for doc_type='note' threading semantics
-- (Spec#3194 I4 hybrid parent-relation design — fast queries via denormalized
-- fields + the relations table for authoritative parent linkage):
--   - root_parent_doc_id INT NULL: pointer to top-of-thread spec/plan/decision
--   - depth SMALLINT NOT NULL DEFAULT 0: recursion-guard tracking (M2.6 enforces
--     max depth 10 with WARN at depth>=5)
-- Plus an index on root_parent_doc_id for fast thread-queries.
--
-- Columns apply only to doc_type='note' rows semantically. For all other doc_types
-- they stay NULL/0 (root_parent_doc_id is NULLable; depth defaults to 0).
--
-- Idempotent (IF NOT EXISTS) — safe to re-run.

ALTER TABLE documents
  ADD COLUMN IF NOT EXISTS root_parent_doc_id INT NULL,
  ADD COLUMN IF NOT EXISTS depth SMALLINT NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_documents_root_parent ON documents(root_parent_doc_id);
