-- Runs only on first datadir init (docker-entrypoint-initdb.d).
-- compute_rack (rack agents) + empty STARTER shell (full schema/users via starter init).
-- rack-user password is set by 02-rack-user.sh when MYSQL_RACK_PASSWORD is provided.

CREATE DATABASE IF NOT EXISTS compute_rack
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS STARTER
  CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

FLUSH PRIVILEGES;

USE compute_rack;

CREATE TABLE IF NOT EXISTS node_hardware (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    node_id VARCHAR(128) NOT NULL,
    timestamp INT UNSIGNED NOT NULL,
    payload JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_node_time (node_id, timestamp)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
