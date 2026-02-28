CREATE TABLE `backup_files` (
	`id` int AUTO_INCREMENT NOT NULL,
	`run_id` int NOT NULL,
	`file_name` varchar(512) NOT NULL,
	`file_path` varchar(1024) NOT NULL,
	`file_type` enum('mariadb-backup','dump','volume','config') NOT NULL,
	`size_bytes` bigint DEFAULT 0,
	`checksum_sha256` varchar(64),
	`created_at` timestamp NOT NULL DEFAULT (UTC_TIMESTAMP()),
	`archived_at` timestamp,
	CONSTRAINT `backup_files_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `backup_runs` (
	`id` int AUTO_INCREMENT NOT NULL,
	`trigger_type` enum('scheduled','manual') NOT NULL DEFAULT 'scheduled',
	`status` enum('running','success','failed','partial') NOT NULL DEFAULT 'running',
	`backup_mode` enum('full','incremental') NOT NULL DEFAULT 'full',
	`started_at` timestamp NOT NULL,
	`completed_at` timestamp,
	`duration_seconds` int,
	`total_size_bytes` bigint DEFAULT 0,
	`error_message` text,
	`archived_at` timestamp,
	`created_at` timestamp NOT NULL DEFAULT (UTC_TIMESTAMP()),
	CONSTRAINT `backup_runs_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `destinations` (
	`id` int AUTO_INCREMENT NOT NULL,
	`name` varchar(255) NOT NULL,
	`type` enum('s3','sftp') NOT NULL,
	`enabled` boolean NOT NULL DEFAULT true,
	`host_or_endpoint` varchar(512),
	`port` int,
	`bucket_or_path` varchar(512),
	`access_key_or_user` varchar(255),
	`secret_name` varchar(255),
	`region` varchar(64),
	`path_prefix` varchar(512),
	`sftp_auth_type` enum('password','key'),
	`created_at` timestamp NOT NULL DEFAULT (UTC_TIMESTAMP()),
	`archived_at` timestamp,
	CONSTRAINT `destinations_id` PRIMARY KEY(`id`),
	CONSTRAINT `idx_dest_name_active` UNIQUE(`name`,`archived_at`)
);
--> statement-breakpoint
CREATE TABLE `retention_events` (
	`id` int AUTO_INCREMENT NOT NULL,
	`file_path` varchar(1024) NOT NULL,
	`file_size_bytes` bigint DEFAULT 0,
	`deleted_at` timestamp NOT NULL,
	`reason` enum('age_exceeded','manual') NOT NULL DEFAULT 'age_exceeded',
	`retention_days_at_deletion` int NOT NULL,
	`created_at` timestamp NOT NULL DEFAULT (UTC_TIMESTAMP()),
	CONSTRAINT `retention_events_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `schedule_config` (
	`id` int NOT NULL DEFAULT 1,
	`cron_expression` varchar(100) NOT NULL DEFAULT '0 2 * * *',
	`enabled` boolean NOT NULL DEFAULT false,
	`backup_mode` enum('full','incremental') NOT NULL DEFAULT 'full',
	`last_modified_at` timestamp NOT NULL DEFAULT (UTC_TIMESTAMP()),
	`modified_by` varchar(100) DEFAULT 'system',
	CONSTRAINT `schedule_config_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `settings` (
	`id` int AUTO_INCREMENT NOT NULL,
	`key` varchar(255) NOT NULL,
	`value` text,
	`updated_at` timestamp NOT NULL DEFAULT (UTC_TIMESTAMP()),
	`archived_at` timestamp,
	CONSTRAINT `settings_id` PRIMARY KEY(`id`),
	CONSTRAINT `idx_settings_key_active` UNIQUE(`key`,`archived_at`)
);
--> statement-breakpoint
CREATE TABLE `upload_attempts` (
	`id` int AUTO_INCREMENT NOT NULL,
	`file_id` int NOT NULL,
	`destination_id` int NOT NULL,
	`status` enum('pending','success','failed') NOT NULL DEFAULT 'pending',
	`started_at` timestamp NOT NULL,
	`completed_at` timestamp,
	`bytes_transferred` bigint DEFAULT 0,
	`error_message` text,
	`archived_at` timestamp,
	`created_at` timestamp NOT NULL DEFAULT (UTC_TIMESTAMP()),
	CONSTRAINT `upload_attempts_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
ALTER TABLE `backup_files` ADD CONSTRAINT `backup_files_run_id_backup_runs_id_fk` FOREIGN KEY (`run_id`) REFERENCES `backup_runs`(`id`) ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE `upload_attempts` ADD CONSTRAINT `upload_attempts_file_id_backup_files_id_fk` FOREIGN KEY (`file_id`) REFERENCES `backup_files`(`id`) ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE `upload_attempts` ADD CONSTRAINT `upload_attempts_destination_id_destinations_id_fk` FOREIGN KEY (`destination_id`) REFERENCES `destinations`(`id`) ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX `idx_files_run` ON `backup_files` (`run_id`);--> statement-breakpoint
CREATE INDEX `idx_runs_status` ON `backup_runs` (`status`);--> statement-breakpoint
CREATE INDEX `idx_runs_started` ON `backup_runs` (`started_at`);--> statement-breakpoint
CREATE INDEX `idx_retention_deleted` ON `retention_events` (`deleted_at`);--> statement-breakpoint
CREATE INDEX `idx_uploads_file` ON `upload_attempts` (`file_id`);--> statement-breakpoint
CREATE INDEX `idx_uploads_dest` ON `upload_attempts` (`destination_id`);