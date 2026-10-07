-- STARTER database skeleton (from starter-core documentation / production schema).
-- Applied on first container start; does not create MySQL users.

CREATE DATABASE IF NOT EXISTS STARTER
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE STARTER;

CREATE TABLE IF NOT EXISTS labels (
    id INT NOT NULL AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT NOT NULL,
    type VARCHAR(50) NOT NULL,
    unit INT NOT NULL,
    min DOUBLE NOT NULL,
    max DOUBLE NOT NULL,
    step DOUBLE NOT NULL,
    PRIMARY KEY (id),
    INDEX idx_labels_type (type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS history (
    id BIGINT NOT NULL AUTO_INCREMENT,
    timestamp DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    source VARCHAR(100) NOT NULL,
    label_id INT NOT NULL,
    value DOUBLE NOT NULL,
    flags BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (id),
    FOREIGN KEY (label_id) REFERENCES labels(id),
    INDEX idx_label_time (label_id, timestamp),
    INDEX idx_history_source (source)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS stats (
    id                INTEGER PRIMARY KEY AUTO_INCREMENT,
    service_name      VARCHAR(100) NOT NULL UNIQUE,
    updated_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    vmsize_min        REAL NOT NULL,
    vmsize_max        REAL NOT NULL,
    vmsize_last       REAL NOT NULL,

    vmrss_min         REAL NOT NULL,
    vmrss_max         REAL NOT NULL,
    vmrss_last        REAL NOT NULL,

    vmswap_min        REAL NOT NULL,
    vmswap_max        REAL NOT NULL,
    vmswap_last       REAL NOT NULL,

    io_read_min       REAL NOT NULL,
    io_read_max       REAL NOT NULL,
    io_read_last      REAL NOT NULL,

    io_write_min      REAL NOT NULL,
    io_write_max      REAL NOT NULL,
    io_write_last     REAL NOT NULL,

    cpu_min           REAL NOT NULL,
    cpu_max           REAL NOT NULL,
    cpu_last          REAL NOT NULL,

    icswitch_min      REAL NOT NULL,
    icswitch_max      REAL NOT NULL,
    icswitch_last     REAL NOT NULL,

    priority_min      REAL NOT NULL,
    priority_max      REAL NOT NULL,
    priority_last     REAL NOT NULL,

    threads_min       REAL NOT NULL,
    threads_max       REAL NOT NULL,
    threads_last      REAL NOT NULL,
    INDEX idx_service_name (service_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
