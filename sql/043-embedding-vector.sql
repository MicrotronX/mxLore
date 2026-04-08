-- =============================================================================
-- 043: Semantic Search — Embedding VECTOR + Stale-Tracking + Trigger
-- Requires: MariaDB 11.6+ (VECTOR column type)
-- =============================================================================

-- Embedding vector (dimensions configurable via INI, default 1536)
ALTER TABLE `documents` ADD COLUMN `embedding` VECTOR(1536) DEFAULT NULL;

-- Stale flag: 1 = embedding needs refresh, 0 = up to date
ALTER TABLE `documents` ADD COLUMN `embedding_stale` TINYINT(1) NOT NULL DEFAULT 1;

-- Index for batch job: quickly find docs needing embedding refresh
CREATE INDEX `idx_embedding_stale` ON `documents` (`embedding_stale`, `doc_type`);

-- Trigger: auto-set embedding_stale=1 on INSERT
DELIMITER //
CREATE TRIGGER `trg_documents_embedding_stale_insert`
BEFORE INSERT ON `documents`
FOR EACH ROW
BEGIN
  SET NEW.embedding_stale = 1;
END//

-- Trigger: auto-set embedding_stale=1 on content/title change
CREATE TRIGGER `trg_documents_embedding_stale_update`
BEFORE UPDATE ON `documents`
FOR EACH ROW
BEGIN
  IF NEW.content != OLD.content OR NEW.title != OLD.title THEN
    SET NEW.embedding_stale = 1;
    SET NEW.embedding = NULL;
  END IF;
END//
DELIMITER ;
