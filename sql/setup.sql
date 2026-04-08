-- =============================================================================
-- mxLore Knowledge Database — Schema Setup
-- Copyright (c) 2026 MicrotronX Software. Licensed under BSL 1.1.
-- See LICENSE file in repository root.
--
-- mxLore is a self-hosted MCP server for AI-assisted software development.
-- It stores architectural decisions, specs, plans, findings, and lessons
-- learned — accessed via Model Context Protocol (MCP) tools from AI coding
-- assistants like Claude Code.
--
-- Version: 1.0.0 (Build 71)
-- Engine:  MariaDB 10.6+ (uses CHECK constraints, JSON functions, partitioning)
-- Charset: utf8mb4_unicode_ci
--
-- Usage:
--   1. CREATE DATABASE mxai_knowledge CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
--   2. mysql -u root -p mxai_knowledge < setup.sql
--   3. The mxLore server will auto-create its project on first boot.
--
-- Optional: Create a dedicated DB user for production:
--   CREATE USER 'mxlore'@'localhost' IDENTIFIED BY 'your_password';
--   GRANT ALL ON mxai_knowledge.* TO 'mxlore'@'localhost';
--
-- All type/status columns use VARCHAR(30). Validation is enforced by the
-- Delphi server (whitelists in tool handlers), not by DB constraints.
-- This avoids ALTER TABLE migrations when adding new values.
-- =============================================================================

USE mxai_knowledge;
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------------
-- Core Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `schema_meta` (
  `key_name` varchar(50) NOT NULL,
  `value` varchar(255) DEFAULT NULL,
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`key_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `developers` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(100) NOT NULL,
  `email` varchar(255) DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `idx_dev_email` (`email`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `projects` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `slug` varchar(100) NOT NULL,
  `name` varchar(255) NOT NULL,
  `path` varchar(500) NOT NULL,
  `svn_url` varchar(500) DEFAULT NULL,
  `briefing` text DEFAULT NULL,
  `dna` text DEFAULT NULL,
  `project_rules` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `deleted_at` datetime DEFAULT NULL,
  `created_by` varchar(100) DEFAULT NULL,
  `created_by_developer_id` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_project_slug` (`slug`),
  KEY `fk_projects_created_by` (`created_by_developer_id`),
  CONSTRAINT `fk_projects_created_by` FOREIGN KEY (`created_by_developer_id`) REFERENCES `developers` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Auth & Access
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `client_keys` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `developer_id` int(11) NOT NULL,
  `key_hash` varchar(255) NOT NULL,
  `key_prefix` varchar(12) DEFAULT NULL,
  `name` varchar(100) NOT NULL,
  `permissions` varchar(30) NOT NULL DEFAULT 'read',
  `last_used_at` datetime DEFAULT NULL,
  `last_used_ip` varchar(45) DEFAULT NULL,
  `expires_at` datetime DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `idx_key_hash` (`key_hash`),
  KEY `fk_client_keys_developer` (`developer_id`),
  KEY `idx_client_keys_prefix` (`key_prefix`),
  CONSTRAINT `fk_client_keys_developer` FOREIGN KEY (`developer_id`) REFERENCES `developers` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `developer_project_access` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `developer_id` int(11) NOT NULL,
  `project_id` int(11) NOT NULL,
  `access_level` varchar(30) NOT NULL DEFAULT 'read',
  `granted_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_dev_project` (`developer_id`,`project_id`),
  KEY `fk_dpa_project` (`project_id`),
  CONSTRAINT `fk_dpa_developer` FOREIGN KEY (`developer_id`) REFERENCES `developers` (`id`),
  CONSTRAINT `fk_dpa_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `developer_environments` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `client_key_id` int(11) NOT NULL,
  `project_id` int(11) NOT NULL,
  `env_key` varchar(100) NOT NULL,
  `env_value` varchar(500) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_env` (`client_key_id`,`project_id`,`env_key`),
  KEY `fk_env_project` (`project_id`),
  CONSTRAINT `fk_env_client_key` FOREIGN KEY (`client_key_id`) REFERENCES `client_keys` (`id`),
  CONSTRAINT `fk_env_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `admin_sessions` (
  `token` varchar(64) NOT NULL,
  `developer_id` int(11) NOT NULL,
  `csrf_token` varchar(64) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `expires_at` timestamp NOT NULL,
  PRIMARY KEY (`token`),
  KEY `fk_admin_session_dev` (`developer_id`),
  CONSTRAINT `fk_admin_session_dev` FOREIGN KEY (`developer_id`) REFERENCES `developers` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Documents (core knowledge store)
-- Central table: all specs, plans, decisions, findings, lessons, notes etc.
-- doc_type and status are VARCHAR(30) — server validates, no ALTER TABLE needed.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `documents` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `project_id` int(11) NOT NULL,
  `doc_type` varchar(30) NOT NULL DEFAULT 'note',
  `slug` varchar(100) NOT NULL,
  `title` varchar(255) NOT NULL,
  `status` varchar(30) NOT NULL DEFAULT 'draft',
  `summary_l1` varchar(500) DEFAULT NULL,
  `summary_l2` text DEFAULT NULL,
  `content` mediumtext DEFAULT NULL,
  `metadata` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`metadata`)),
  `relevance_score` decimal(5,2) NOT NULL DEFAULT 50.00,
  `token_estimate` int(11) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `created_by` varchar(100) DEFAULT NULL,
  `access_count` int(11) NOT NULL DEFAULT 0,
  `confidence` decimal(3,2) NOT NULL DEFAULT 0.50,
  `lesson_data` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL COMMENT 'Structured lesson metadata (JSON). Only for doc_type=lesson.' CHECK (json_valid(`lesson_data`)),
  `violation_count` int(11) NOT NULL DEFAULT 0 COMMENT 'Times this lesson was violated',
  `success_count` int(11) NOT NULL DEFAULT 0 COMMENT 'Times this lesson was applied successfully',
  `embedding` VECTOR(1536) DEFAULT NULL,
  `embedding_stale` TINYINT(1) NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_doc` (`project_id`,`doc_type`,`slug`),
  KEY `idx_project_type` (`project_id`,`doc_type`,`status`),
  KEY `idx_relevance` (`relevance_score`),
  KEY `idx_documents_lesson_scope` (`doc_type`,`status`) COMMENT 'Optimizes lesson queries in mx_recall',
  KEY `idx_embedding_stale` (`embedding_stale`, `doc_type`),
  FULLTEXT KEY `ft_documents` (`title`,`summary_l2`,`content`),
  CONSTRAINT `fk_doc_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Embedding stale triggers (auto-set on content/title changes)
DELIMITER //
CREATE TRIGGER IF NOT EXISTS `trg_documents_embedding_stale_insert`
BEFORE INSERT ON `documents`
FOR EACH ROW
BEGIN
  SET NEW.embedding_stale = 1;
END//

CREATE TRIGGER IF NOT EXISTS `trg_documents_embedding_stale_update`
BEFORE UPDATE ON `documents`
FOR EACH ROW
BEGIN
  IF NEW.content != OLD.content OR NEW.title != OLD.title THEN
    SET NEW.embedding_stale = 1;
    SET NEW.embedding = NULL;
  END IF;
END//
DELIMITER ;

CREATE TABLE IF NOT EXISTS `doc_tags` (
  `doc_id` int(11) NOT NULL,
  `tag` varchar(50) NOT NULL,
  PRIMARY KEY (`doc_id`,`tag`),
  KEY `idx_tag` (`tag`,`doc_id`),
  CONSTRAINT `fk_tag_doc` FOREIGN KEY (`doc_id`) REFERENCES `documents` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `doc_relations` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `source_doc_id` int(11) NOT NULL,
  `target_doc_id` int(11) NOT NULL,
  `relation_type` varchar(30) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_relation` (`source_doc_id`,`target_doc_id`,`relation_type`),
  KEY `idx_rel_source` (`source_doc_id`,`relation_type`),
  KEY `idx_rel_target` (`target_doc_id`,`relation_type`),
  CONSTRAINT `fk_rel_source` FOREIGN KEY (`source_doc_id`) REFERENCES `documents` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_rel_target` FOREIGN KEY (`target_doc_id`) REFERENCES `documents` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `doc_revisions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `doc_id` int(11) NOT NULL,
  `revision` int(11) NOT NULL,
  `content` mediumtext DEFAULT NULL,
  `summary_l2` text DEFAULT NULL,
  `changed_by` varchar(100) DEFAULT NULL,
  `changed_at` datetime NOT NULL DEFAULT current_timestamp(),
  `change_reason` varchar(500) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_revision` (`doc_id`,`revision`),
  CONSTRAINT `fk_rev_doc` FOREIGN KEY (`doc_id`) REFERENCES `documents` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Sessions & Access Tracking
-- Note: sessions has no FK constraints (MariaDB does not support FK on
-- partitioned tables). access_log has no FKs by design (high-insert table).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `sessions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `project_id` int(11) NOT NULL,
  `developer_id` int(11) DEFAULT NULL,
  `client_key_id` int(11) DEFAULT NULL,
  `setup_version` varchar(50) DEFAULT NULL,
  `instance_id` varchar(100) NOT NULL,
  `started_at` datetime NOT NULL DEFAULT current_timestamp(),
  `last_heartbeat` datetime DEFAULT NULL,
  `ended_at` datetime DEFAULT NULL,
  `summary` text DEFAULT NULL,
  `files_touched` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL COMMENT 'JSON array of file paths' CHECK (json_valid(`files_touched`)),
  PRIMARY KEY (`id`,`started_at`),
  KEY `idx_session_project` (`project_id`,`started_at`),
  KEY `idx_session_developer` (`developer_id`),
  KEY `idx_session_key` (`client_key_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
 PARTITION BY RANGE (year(`started_at`))
(PARTITION `p2025` VALUES LESS THAN (2026) ENGINE = InnoDB,
 PARTITION `p2026` VALUES LESS THAN (2027) ENGINE = InnoDB,
 PARTITION `p2027` VALUES LESS THAN (2028) ENGINE = InnoDB,
 PARTITION `p2028` VALUES LESS THAN (2029) ENGINE = InnoDB,
 PARTITION `p2029` VALUES LESS THAN (2030) ENGINE = InnoDB,
 PARTITION `p2030` VALUES LESS THAN (2031) ENGINE = InnoDB,
 PARTITION `pmax` VALUES LESS THAN MAXVALUE ENGINE = InnoDB);

CREATE TABLE IF NOT EXISTS `access_log` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `doc_id` int(11) NOT NULL,
  `session_id` int(11) DEFAULT NULL,
  `developer_id` int(11) DEFAULT NULL,
  `tool_name` varchar(50) DEFAULT NULL,
  `context_tool` varchar(50) DEFAULT NULL,
  `project_id` int(11) DEFAULT NULL,
  `created_at` datetime(3) DEFAULT current_timestamp(3),
  PRIMARY KEY (`id`),
  KEY `idx_doc` (`doc_id`),
  KEY `idx_session` (`session_id`),
  KEY `idx_created` (`created_at`),
  KEY `idx_project_created` (`project_id`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `tool_call_log` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `tool_name` varchar(50) NOT NULL,
  `session_id` int(11) DEFAULT NULL,
  `developer_id` int(11) DEFAULT NULL,
  `response_bytes` int(11) NOT NULL DEFAULT 0,
  `latency_ms` int(11) NOT NULL DEFAULT 0,
  `is_error` tinyint(1) NOT NULL DEFAULT 0,
  `error_code` varchar(30) DEFAULT NULL,
  `created_at` datetime(3) DEFAULT current_timestamp(3),
  PRIMARY KEY (`id`),
  KEY `idx_tcl_tool` (`tool_name`),
  KEY `idx_tcl_session` (`session_id`),
  KEY `idx_tcl_created` (`created_at`),
  KEY `idx_tcl_tool_created` (`tool_name`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `access_patterns` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `project_id` int(11) NOT NULL,
  `doc_id` int(11) NOT NULL,
  `score` decimal(3,2) NOT NULL,
  `reason` varchar(20) NOT NULL,
  `sessions_hit` int(11) NOT NULL DEFAULT 0,
  `sessions_total` int(11) NOT NULL DEFAULT 0,
  `calculated_at` datetime(3) DEFAULT current_timestamp(3),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_project_doc` (`project_id`,`doc_id`),
  KEY `idx_project_score` (`project_id`,`score` DESC),
  KEY `idx_doc` (`doc_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Multi-Agent Communication
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `agent_messages` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `sender_session_id` int(11) NOT NULL,
  `sender_project_id` int(11) NOT NULL,
  `sender_developer_id` int(11) NOT NULL,
  `target_project_id` int(11) NOT NULL,
  `message_type` varchar(30) NOT NULL,
  `payload` text NOT NULL,
  `ref_doc_id` int(11) DEFAULT NULL,
  `ref_message_id` int(11) DEFAULT NULL,
  `priority` varchar(30) NOT NULL DEFAULT 'normal',
  `status` varchar(30) NOT NULL DEFAULT 'pending',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `read_at` datetime DEFAULT NULL,
  `expires_at` datetime DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_am_ref_doc` (`ref_doc_id`),
  KEY `idx_am_inbox` (`target_project_id`,`status`,`created_at`),
  KEY `idx_am_sender` (`sender_project_id`,`created_at`),
  KEY `idx_am_ref_msg` (`ref_message_id`),
  CONSTRAINT `fk_am_ref_doc` FOREIGN KEY (`ref_doc_id`) REFERENCES `documents` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_am_sender_project` FOREIGN KEY (`sender_project_id`) REFERENCES `projects` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_am_target_project` FOREIGN KEY (`target_project_id`) REFERENCES `projects` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `notifications` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `project_id` int(11) DEFAULT NULL,
  `severity` varchar(30) NOT NULL DEFAULT 'info',
  `message` varchar(500) NOT NULL,
  `source_doc_id` int(11) DEFAULT NULL,
  `acknowledged` tinyint(1) NOT NULL DEFAULT 0,
  `is_archived` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `expires_at` datetime DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `fk_notif_doc` (`source_doc_id`),
  KEY `idx_notif_project` (`project_id`,`acknowledged`,`is_archived`),
  CONSTRAINT `fk_notif_doc` FOREIGN KEY (`source_doc_id`) REFERENCES `documents` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_notif_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `project_relations` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `source_project_id` int(11) NOT NULL,
  `target_project_id` int(11) NOT NULL,
  `relation_type` varchar(50) NOT NULL,
  `created_at` timestamp NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_proj_rel` (`source_project_id`,`target_project_id`,`relation_type`),
  KEY `idx_pr_target` (`target_project_id`,`relation_type`),
  CONSTRAINT `fk_pr_source` FOREIGN KEY (`source_project_id`) REFERENCES `projects` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_pr_target` FOREIGN KEY (`target_project_id`) REFERENCES `projects` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- AI Batch & Skill Evolution
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `ai_batch_log` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `job_type` varchar(50) NOT NULL COMMENT 'summary, tagging, stale_detection, stub_warning, etc.',
  `doc_id` int(11) DEFAULT NULL COMMENT 'FK documents.id (NULL for summary entries)',
  `project_id` int(11) DEFAULT NULL COMMENT 'FK projects.id (NULL for global entries)',
  `field_name` varchar(100) NOT NULL,
  `old_value` text DEFAULT NULL,
  `new_value` text DEFAULT NULL,
  `model` varchar(100) NOT NULL,
  `tokens_input` int(11) NOT NULL DEFAULT 0,
  `tokens_output` int(11) NOT NULL DEFAULT 0,
  `status` varchar(20) NOT NULL DEFAULT 'success',
  `error_message` varchar(500) DEFAULT NULL,
  `duration_ms` int(11) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_abl_job_type` (`job_type`,`created_at`),
  KEY `idx_abl_doc` (`doc_id`),
  KEY `idx_abl_project` (`project_id`,`job_type`),
  KEY `idx_abl_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `recall_log` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT,
  `session_id` int(11) DEFAULT NULL,
  `project_id` int(11) NOT NULL,
  `query` varchar(500) NOT NULL DEFAULT '',
  `intent` varchar(50) NOT NULL DEFAULT 'general',
  `target_file` varchar(500) NOT NULL DEFAULT '',
  `treffer_count` int(11) NOT NULL DEFAULT 0,
  `top_score` double NOT NULL DEFAULT 0,
  `budget_class` varchar(20) NOT NULL DEFAULT 'tiny',
  `latency_ms` int(11) NOT NULL DEFAULT 0,
  `outcome` varchar(30) NOT NULL DEFAULT 'shown',
  `gate_level` varchar(10) DEFAULT NULL,
  `gate_reason` varchar(500) DEFAULT NULL,
  `triggered_lesson_ids` varchar(500) DEFAULT NULL,
  `override_reason` varchar(500) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_recall_log_session` (`session_id`),
  KEY `idx_recall_log_project` (`project_id`,`created_at`),
  KEY `idx_recall_log_outcome` (`outcome`,`created_at`),
  KEY `idx_recall_log_cooldown` (`project_id`,`query`(50),`intent`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `skill_findings` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `finding_uid` varchar(128) NOT NULL COMMENT 'Stable UID: skill:rule:context_hash',
  `skill_name` varchar(100) NOT NULL,
  `rule_id` varchar(100) NOT NULL,
  `project_id` int(11) NOT NULL,
  `severity` varchar(30) NOT NULL DEFAULT 'info',
  `title` varchar(255) NOT NULL,
  `context_hash` varchar(64) DEFAULT NULL,
  `file_path` varchar(500) DEFAULT NULL,
  `line_number` int(11) DEFAULT NULL,
  `details` text DEFAULT NULL,
  `user_reaction` varchar(30) NOT NULL DEFAULT 'pending',
  `reacted_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_finding_uid` (`finding_uid`),
  KEY `idx_sf_skill_project` (`skill_name`,`project_id`),
  KEY `idx_sf_rule` (`skill_name`,`rule_id`),
  KEY `idx_sf_reaction` (`user_reaction`,`skill_name`),
  KEY `idx_sf_created` (`created_at`),
  KEY `fk_sf_project` (`project_id`),
  CONSTRAINT `fk_sf_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `skill_params` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `skill_name` varchar(100) NOT NULL,
  `project_id` int(11) NOT NULL,
  `param_key` varchar(100) NOT NULL,
  `param_value` text NOT NULL,
  `version` int(11) NOT NULL DEFAULT 1,
  `previous_value` text DEFAULT NULL COMMENT 'For 1-step rollback',
  `change_reason` varchar(500) DEFAULT NULL,
  `change_metrics` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`change_metrics`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_sp_skill_project_param` (`skill_name`,`project_id`,`param_key`),
  KEY `idx_sp_skill_project` (`skill_name`,`project_id`),
  KEY `fk_sp_project` (`project_id`),
  CONSTRAINT `fk_sp_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `graph_nodes` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `node_type` varchar(30) NOT NULL,
  `name` varchar(500) NOT NULL,
  `project_id` int(11) DEFAULT NULL,
  `doc_id` int(11) DEFAULT NULL,
  `metadata` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`metadata`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_node` (`node_type`,`name`,`project_id`),
  KEY `idx_node_project` (`project_id`),
  KEY `idx_node_type` (`node_type`),
  KEY `idx_node_doc` (`doc_id`),
  CONSTRAINT `fk_node_project` FOREIGN KEY (`project_id`) REFERENCES `projects` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_node_doc` FOREIGN KEY (`doc_id`) REFERENCES `documents` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `graph_edges` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `source_node_id` int(11) NOT NULL,
  `target_node_id` int(11) NOT NULL,
  `edge_type` varchar(30) NOT NULL,
  `weight` float NOT NULL DEFAULT 1.0,
  `metadata` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`metadata`)),
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_edge` (`source_node_id`,`target_node_id`,`edge_type`),
  KEY `idx_edge_source` (`source_node_id`,`edge_type`),
  KEY `idx_edge_target` (`target_node_id`,`edge_type`),
  KEY `idx_edge_type` (`edge_type`),
  CONSTRAINT `fk_edge_source` FOREIGN KEY (`source_node_id`) REFERENCES `graph_nodes` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_edge_target` FOREIGN KEY (`target_node_id`) REFERENCES `graph_nodes` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Stored Procedures
-- ---------------------------------------------------------------------------

DELIMITER //

CREATE PROCEDURE `sp_briefing`(
  IN p_project_slug VARCHAR(100),
  IN p_token_budget INT
)
BEGIN
  DECLARE v_project_id INT;
  DECLARE v_budget INT;

  SELECT id INTO v_project_id
  FROM projects
  WHERE slug = p_project_slug;

  IF v_project_id IS NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'PROJECT_NOT_FOUND';
  END IF;

  SET v_budget = IFNULL(p_token_budget, 2000);

  SELECT p.id, p.slug, p.name, p.path, p.svn_url, p.briefing, p.dna,
         CEIL(CHAR_LENGTH(IFNULL(p.briefing, '')) / 3.5) AS briefing_tokens
  FROM projects p
  WHERE p.id = v_project_id;

  SELECT d.id, d.doc_type, d.slug, d.title, d.status,
         d.summary_l1, d.relevance_score, d.token_estimate, d.updated_at
  FROM (
    SELECT d2.*,
           SUM(IFNULL(d2.token_estimate, 0))
             OVER (ORDER BY d2.relevance_score DESC
                   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_tokens
    FROM documents d2
    WHERE d2.project_id = v_project_id
      AND d2.status IN ('draft', 'active')
  ) d
  WHERE d.cumulative_tokens - d.token_estimate < v_budget
  ORDER BY d.relevance_score DESC
  LIMIT 50;
END//

CREATE PROCEDURE `sp_detail`(
  IN p_doc_id INT
)
BEGIN
  SELECT d.id, p.slug AS project, d.doc_type, d.slug, d.title, d.status,
         d.summary_l1, d.summary_l2, d.content, d.metadata,
         d.relevance_score, d.token_estimate,
         d.created_at, d.updated_at, d.created_by
  FROM documents d
  JOIN projects p ON d.project_id = p.id
  WHERE d.id = p_doc_id;

  SELECT tag
  FROM doc_tags
  WHERE doc_id = p_doc_id
  ORDER BY tag;

  SELECT dr.id AS relation_id, dr.relation_type,
         dr.source_doc_id, ds.title AS source_title, ds.doc_type AS source_type,
         dr.target_doc_id, dt.title AS target_title, dt.doc_type AS target_type
  FROM doc_relations dr
  JOIN documents ds ON ds.id = dr.source_doc_id
  JOIN documents dt ON dt.id = dr.target_doc_id
  WHERE dr.source_doc_id = p_doc_id OR dr.target_doc_id = p_doc_id;
END//

CREATE PROCEDURE `sp_relations`(
  IN p_doc_id INT,
  IN p_depth  INT
)
BEGIN
  DECLARE v_current_depth INT DEFAULT 0;
  DECLARE v_new_count INT DEFAULT 0;

  SET p_depth = LEAST(IFNULL(p_depth, 1), 5);

  DROP TEMPORARY TABLE IF EXISTS tmp_rel_visited;
  DROP TEMPORARY TABLE IF EXISTS tmp_rel_results;

  CREATE TEMPORARY TABLE tmp_rel_visited (
    doc_id INT PRIMARY KEY
  ) ENGINE=MEMORY;

  CREATE TEMPORARY TABLE tmp_rel_results (
    source_doc_id INT,
    target_doc_id INT,
    relation_type VARCHAR(50),
    depth         INT,
    INDEX idx_tmp_depth (depth)
  ) ENGINE=MEMORY;

  INSERT INTO tmp_rel_visited (doc_id) VALUES (p_doc_id);

  WHILE v_current_depth < p_depth DO
    SET v_current_depth = v_current_depth + 1;

    INSERT INTO tmp_rel_results (source_doc_id, target_doc_id, relation_type, depth)
    SELECT dr.source_doc_id, dr.target_doc_id, dr.relation_type, v_current_depth
    FROM doc_relations dr
    WHERE (dr.source_doc_id IN (SELECT doc_id FROM tmp_rel_visited)
           OR dr.target_doc_id IN (SELECT doc_id FROM tmp_rel_visited))
      AND NOT EXISTS (
        SELECT 1 FROM tmp_rel_results tr
        WHERE tr.source_doc_id = dr.source_doc_id
          AND tr.target_doc_id = dr.target_doc_id
          AND tr.relation_type = dr.relation_type
      );

    INSERT IGNORE INTO tmp_rel_visited (doc_id)
    SELECT source_doc_id FROM tmp_rel_results WHERE depth = v_current_depth
    UNION
    SELECT target_doc_id FROM tmp_rel_results WHERE depth = v_current_depth;

    SELECT COUNT(*) INTO v_new_count
    FROM tmp_rel_results
    WHERE depth = v_current_depth;

    IF v_new_count = 0 THEN
      SET v_current_depth = p_depth;
    END IF;
  END WHILE;

  SELECT tr.source_doc_id, tr.target_doc_id, tr.relation_type, tr.depth,
         ds.title AS source_title, ds.doc_type AS source_type, ds.status AS source_status,
         dt.title AS target_title, dt.doc_type AS target_type, dt.status AS target_status
  FROM tmp_rel_results tr
  JOIN documents ds ON ds.id = tr.source_doc_id
  JOIN documents dt ON dt.id = tr.target_doc_id
  ORDER BY tr.depth, tr.source_doc_id;

  DROP TEMPORARY TABLE IF EXISTS tmp_rel_visited;
  DROP TEMPORARY TABLE IF EXISTS tmp_rel_results;
END//

CREATE PROCEDURE `sp_search`(
  IN p_query VARCHAR(255),
  IN p_scope VARCHAR(10),
  IN p_project_slug VARCHAR(100),
  IN p_doc_type VARCHAR(200),
  IN p_token_budget INT
)
BEGIN
  DECLARE v_project_id INT DEFAULT NULL;
  DECLARE v_budget INT;

  SET v_budget = IFNULL(p_token_budget, 1500);
  SET p_scope = IFNULL(p_scope, 'all');
  SET p_query = TRIM(p_query);

  IF p_query = '' OR p_query IS NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'EMPTY_QUERY';
  END IF;

  IF p_scope = 'project' AND p_project_slug IS NOT NULL THEN
    SELECT id INTO v_project_id FROM projects WHERE slug = p_project_slug AND is_active = TRUE;
    IF v_project_id IS NULL THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'PROJECT_NOT_FOUND';
    END IF;
  END IF;

  SELECT d.id, p.slug AS project, d.doc_type, d.title,
         d.summary_l1, d.summary_l2,
         ROUND(MATCH(d.title, d.summary_l2, d.content) AGAINST(p_query IN NATURAL LANGUAGE MODE), 2) AS relevance_score,
         d.token_estimate
  FROM documents d
  JOIN projects p ON d.project_id = p.id
  WHERE d.status != 'deleted'
    AND p.is_active = TRUE
    AND (v_project_id IS NULL OR d.project_id = v_project_id)
    AND (p_doc_type IS NULL OR p_doc_type = '' OR FIND_IN_SET(d.doc_type, p_doc_type) > 0)
    AND MATCH(d.title, d.summary_l2, d.content) AGAINST(p_query IN NATURAL LANGUAGE MODE)
  ORDER BY relevance_score DESC
  LIMIT 50;
END//

DELIMITER ;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

DELIMITER //

CREATE TRIGGER trg_doc_token_insert
BEFORE INSERT ON documents
FOR EACH ROW
BEGIN
  IF NEW.content IS NOT NULL THEN
    SET NEW.token_estimate = CEIL(CHAR_LENGTH(NEW.content) / 3.5);
  END IF;
END//

CREATE TRIGGER trg_doc_token_update
BEFORE UPDATE ON documents
FOR EACH ROW
BEGIN
  IF NEW.content IS NOT NULL THEN
    SET NEW.token_estimate = CEIL(CHAR_LENGTH(NEW.content) / 3.5);
  END IF;
END//

CREATE TRIGGER trg_decision_impact
AFTER UPDATE ON documents
FOR EACH ROW
BEGIN
  IF NEW.status = 'superseded' AND OLD.status != 'superseded' THEN
    INSERT INTO notifications (project_id, severity, message, source_doc_id, created_at)
    SELECT
      d.project_id,
      'action_required',
      CONCAT('Review needed: referenced doc "', NEW.title, '" (ID ', NEW.id, ') was superseded'),
      dr.source_doc_id,
      NOW()
    FROM doc_relations dr
    JOIN documents d ON d.id = dr.source_doc_id
    WHERE dr.target_doc_id = NEW.id;
  END IF;
END//

DELIMITER ;

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW `v_admin_project_overview` AS
SELECT
  p.id, p.slug, p.name, p.is_active, p.created_at, p.deleted_at,
  p.created_by_developer_id,
  COALESCE(d.name, p.created_by, 'System') AS created_by_name,
  (SELECT COUNT(*) FROM documents doc WHERE doc.project_id = p.id AND doc.status != 'deleted') AS doc_count,
  (SELECT COUNT(DISTINCT dpa.developer_id) FROM developer_project_access dpa WHERE dpa.project_id = p.id) AS developer_count,
  (SELECT MAX(doc.updated_at) FROM documents doc WHERE doc.project_id = p.id) AS last_activity
FROM projects p
LEFT JOIN developers d ON d.id = p.created_by_developer_id;

CREATE OR REPLACE VIEW `v_cross_project_search` AS
SELECT d.id, p.slug AS project, d.doc_type, d.title, d.summary_l1,
       d.summary_l2, d.status, d.relevance_score, d.token_estimate
FROM documents d
JOIN projects p ON d.project_id = p.id;

CREATE OR REPLACE VIEW `v_open_tasks` AS
SELECT p.slug AS project, d.id AS doc_id, d.doc_type, d.title,
       d.summary_l1, d.status, d.relevance_score, d.updated_at
FROM documents d
JOIN projects p ON d.project_id = p.id
WHERE d.status IN ('draft','active')
  AND d.doc_type IN ('plan','finding')
ORDER BY d.relevance_score DESC;

CREATE OR REPLACE VIEW `v_project_overview` AS
SELECT d.id, d.project_id, d.doc_type, d.slug, d.title, d.status,
       d.summary_l1, d.relevance_score, d.token_estimate, d.updated_at
FROM documents d
WHERE d.status IN ('draft','active')
ORDER BY d.relevance_score DESC;

CREATE OR REPLACE VIEW `v_recent_decisions` AS
SELECT p.slug AS project, d.id AS doc_id, d.title, d.summary_l2,
       d.status, d.updated_at
FROM documents d
JOIN projects p ON d.project_id = p.id
WHERE d.doc_type = 'decision'
ORDER BY d.updated_at DESC;

-- ---------------------------------------------------------------------------
-- Seed Data
-- ---------------------------------------------------------------------------

INSERT INTO schema_meta (key_name, value) VALUES
  ('schema_version', '1.0.0'),
  ('last_migration', NOW()),
  ('last_backup', 'never')
ON DUPLICATE KEY UPDATE value = VALUES(value), updated_at = NOW();

-- Global sentinel project (required for cross-project environment variables)
INSERT IGNORE INTO projects (slug, name, path) VALUES ('_global', 'Global', '');

SET FOREIGN_KEY_CHECKS = 1;
