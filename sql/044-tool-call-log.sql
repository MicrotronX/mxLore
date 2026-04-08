-- =============================================================================
-- 044: Tool Call Log — central MCP call metrics (latency, response size, errors)
-- =============================================================================

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
