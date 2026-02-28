import {
  mysqlTable,
  int,
  varchar,
  text,
  timestamp,
  bigint,
  boolean,
  mysqlEnum,
  index,
  uniqueIndex,
} from "drizzle-orm/mysql-core";
import { sql } from "drizzle-orm";

// ---------------------------------------------------------------------------
// backup_runs — one row per backup execution
// ---------------------------------------------------------------------------
export const backupRuns = mysqlTable(
  "backup_runs",
  {
    id: int("id").autoincrement().primaryKey(),
    triggerType: mysqlEnum("trigger_type", ["scheduled", "manual"]).notNull().default("scheduled"),
    status: mysqlEnum("status", ["running", "success", "failed", "partial"]).notNull().default("running"),
    backupMode: mysqlEnum("backup_mode", ["full", "incremental"]).notNull().default("full"),
    startedAt: timestamp("started_at", { mode: "string" }).notNull(),
    completedAt: timestamp("completed_at", { mode: "string" }),
    durationSeconds: int("duration_seconds"),
    totalSizeBytes: bigint("total_size_bytes", { mode: "number" }).default(0),
    errorMessage: text("error_message"),
    archivedAt: timestamp("archived_at", { mode: "string" }),
    createdAt: timestamp("created_at", { mode: "string" }).notNull().default(sql`(UTC_TIMESTAMP())`),
  },
  (t) => [index("idx_runs_status").on(t.status), index("idx_runs_started").on(t.startedAt)]
);

// ---------------------------------------------------------------------------
// backup_files — one row per file produced in a run
// ---------------------------------------------------------------------------
export const backupFiles = mysqlTable(
  "backup_files",
  {
    id: int("id").autoincrement().primaryKey(),
    runId: int("run_id").notNull().references(() => backupRuns.id),
    fileName: varchar("file_name", { length: 512 }).notNull(),
    filePath: varchar("file_path", { length: 1024 }).notNull(),
    fileType: mysqlEnum("file_type", ["mariadb-backup", "dump", "volume", "config"]).notNull(),
    sizeBytes: bigint("size_bytes", { mode: "number" }).default(0),
    checksumSha256: varchar("checksum_sha256", { length: 64 }),
    createdAt: timestamp("created_at", { mode: "string" }).notNull().default(sql`(UTC_TIMESTAMP())`),
    archivedAt: timestamp("archived_at", { mode: "string" }),
  },
  (t) => [index("idx_files_run").on(t.runId)]
);

// ---------------------------------------------------------------------------
// destinations — S3 or SFTP upload endpoints
// ---------------------------------------------------------------------------
export const destinations = mysqlTable(
  "destinations",
  {
    id: int("id").autoincrement().primaryKey(),
    name: varchar("name", { length: 255 }).notNull(),
    type: mysqlEnum("type", ["s3", "sftp"]).notNull(),
    enabled: boolean("enabled").notNull().default(true),
    hostOrEndpoint: varchar("host_or_endpoint", { length: 512 }),
    port: int("port"),
    bucketOrPath: varchar("bucket_or_path", { length: 512 }),
    accessKeyOrUser: varchar("access_key_or_user", { length: 255 }),
    secretName: varchar("secret_name", { length: 255 }),  // Podman secret name, NOT value
    region: varchar("region", { length: 64 }),
    pathPrefix: varchar("path_prefix", { length: 512 }),
    sftpAuthType: mysqlEnum("sftp_auth_type", ["password", "key"]),
    createdAt: timestamp("created_at", { mode: "string" }).notNull().default(sql`(UTC_TIMESTAMP())`),
    archivedAt: timestamp("archived_at", { mode: "string" }),
  },
  (t) => [
    uniqueIndex("idx_dest_name_active").on(t.name, t.archivedAt),
  ]
);

// ---------------------------------------------------------------------------
// upload_attempts — one row per file upload to a destination
// ---------------------------------------------------------------------------
export const uploadAttempts = mysqlTable(
  "upload_attempts",
  {
    id: int("id").autoincrement().primaryKey(),
    fileId: int("file_id").notNull().references(() => backupFiles.id),
    destinationId: int("destination_id").notNull().references(() => destinations.id),
    status: mysqlEnum("status", ["pending", "success", "failed"]).notNull().default("pending"),
    startedAt: timestamp("started_at", { mode: "string" }).notNull(),
    completedAt: timestamp("completed_at", { mode: "string" }),
    bytesTransferred: bigint("bytes_transferred", { mode: "number" }).default(0),
    errorMessage: text("error_message"),
    archivedAt: timestamp("archived_at", { mode: "string" }),
    createdAt: timestamp("created_at", { mode: "string" }).notNull().default(sql`(UTC_TIMESTAMP())`),
  },
  (t) => [
    index("idx_uploads_file").on(t.fileId),
    index("idx_uploads_dest").on(t.destinationId),
  ]
);

// ---------------------------------------------------------------------------
// schedule_config — singleton (id = 1 always)
// ---------------------------------------------------------------------------
export const scheduleConfig = mysqlTable("schedule_config", {
  id: int("id").primaryKey().default(1),
  cronExpression: varchar("cron_expression", { length: 100 }).notNull().default("0 2 * * *"),
  enabled: boolean("enabled").notNull().default(false),
  backupMode: mysqlEnum("backup_mode", ["full", "incremental"]).notNull().default("full"),
  lastModifiedAt: timestamp("last_modified_at", { mode: "string" }).notNull().default(sql`(UTC_TIMESTAMP())`),
  modifiedBy: varchar("modified_by", { length: 100 }).default("system"),
});

// ---------------------------------------------------------------------------
// settings — key-value store
// ---------------------------------------------------------------------------
export const settings = mysqlTable(
  "settings",
  {
    id: int("id").autoincrement().primaryKey(),
    key: varchar("key", { length: 255 }).notNull(),
    value: text("value"),
    updatedAt: timestamp("updated_at", { mode: "string" }).notNull().default(sql`(UTC_TIMESTAMP())`),
    archivedAt: timestamp("archived_at", { mode: "string" }),
  },
  (t) => [uniqueIndex("idx_settings_key_active").on(t.key, t.archivedAt)]
);

// ---------------------------------------------------------------------------
// retention_events — audit log for pruned files
// ---------------------------------------------------------------------------
export const retentionEvents = mysqlTable(
  "retention_events",
  {
    id: int("id").autoincrement().primaryKey(),
    filePath: varchar("file_path", { length: 1024 }).notNull(),
    fileSizeBytes: bigint("file_size_bytes", { mode: "number" }).default(0),
    deletedAt: timestamp("deleted_at", { mode: "string" }).notNull(),
    reason: mysqlEnum("reason", ["age_exceeded", "manual"]).notNull().default("age_exceeded"),
    retentionDaysAtDeletion: int("retention_days_at_deletion").notNull(),
    createdAt: timestamp("created_at", { mode: "string" }).notNull().default(sql`(UTC_TIMESTAMP())`),
  },
  (t) => [index("idx_retention_deleted").on(t.deletedAt)]
);
