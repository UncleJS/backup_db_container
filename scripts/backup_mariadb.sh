#!/usr/bin/env bash
# =============================================================================
# scripts/backup_mariadb.sh — MariaDB physical + logical backup
#
# PURPOSE
#   Performs two complementary backups of the target MariaDB server:
#
#   1. Physical hot backup via mariadb-backup (formerly XtraBackup)
#      Produces a binary copy of the InnoDB data files that can be restored
#      with mariadb-backup --prepare + --copy-back.  Advantages:
#        • Hot backup: no table locks, no downtime for InnoDB tables
#        • Supports incremental backups (only changed pages since last full)
#        • Exact byte-for-byte copy; very fast restore for large databases
#
#   2. Logical SQL dump via mariadb-dump
#      Produces a gzip-compressed .sql file with all CREATE and INSERT
#      statements.  Advantages:
#        • Human-readable; useful for inspecting specific tables
#        • Portable across MariaDB versions
#        • Easy to restore a single database or table from a full dump
#
#   Both outputs are registered in the tracking DB via db_record_file().
#
# INCREMENTAL BACKUP LOGIC
#   When MARIADB_BACKUP_MODE=incremental AND a valid last full backup path
#   exists in the .last_full_backup marker file:
#     → incremental backup using --incremental-basedir pointing at last full
#   If the marker file is missing or points to a non-existent directory:
#     → automatic fallback to full backup (safer than failing)
#   When MARIADB_BACKUP_MODE=full:
#     → always perform a full backup and update the .last_full_backup marker
#
# ARGUMENTS (positional)
#   $1  run_dir         — absolute path to the current run's working directory
#   $2  host            — MariaDB hostname or IP to back up
#   $3  port            — MariaDB port (typically 3306)
#   $4  user            — MariaDB user (needs RELOAD, LOCK TABLES, REPLICATION CLIENT)
#   $5  backup_mode     — "full" | "incremental"
#   $6  api_url         — base URL of the tracking API (e.g. http://localhost:3001)
#   $7  run_id          — integer run ID from db_create_run()
#   $8  api_secret      — INTERNAL_API_SECRET for API auth
#
# ENVIRONMENT VARIABLES
#   MARIADB_PASSWORD     — plaintext password for the backup user; populated by
#                          backup.sh from the /run/secrets/mariadb_backup_password
#                          Podman secret before this script is called
#   BACKUP_OUTPUT_DIR    — base backup dir (default: /backups); the .last_full_backup
#                          marker is stored here, not in the run-specific dir, so it
#                          persists across backup runs
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Positional arguments
# ---------------------------------------------------------------------------
RUN_DIR="$1"
MARIADB_HOST="$2"
MARIADB_PORT="$3"
MARIADB_USER="$4"
MARIADB_BACKUP_MODE="$5"    # full | incremental
API_BASE_URL="$6"
RUN_ID="$7"
INTERNAL_API_SECRET="$8"

# Source the API helper library so db_record_file() is available.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/db_record.sh"

# Timestamped log helpers — all output goes to stdout and is captured by
# backup.sh into journald via systemd.
log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [mariadb] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [mariadb][ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# Shared connection arguments reused by both mariadb-backup and mariadb-dump.
# Storing them in an array allows safe expansion with "${MARIADB_ARGS[@]}"
# (handles spaces, special chars in password correctly).
# ---------------------------------------------------------------------------
MARIADB_ARGS=(
  "--host=${MARIADB_HOST}"
  "--port=${MARIADB_PORT}"
  "--user=${MARIADB_USER}"
  "--password=${MARIADB_PASSWORD}"   # MARIADB_PASSWORD is set in the environment
)

# ---------------------------------------------------------------------------
# Path constants
# ---------------------------------------------------------------------------
FULL_BACKUP_BASE="${RUN_DIR}/mariadb-backup-full"
INCR_BACKUP_DIR="${RUN_DIR}/mariadb-backup-incr"

# The .last_full_backup marker stores the path of the most recent successful
# full physical backup directory.  It lives in BACKUP_OUTPUT_DIR (not in the
# per-run dir) so it survives across multiple runs.
# Example content: /backups/20260201-020000/mariadb-backup-full
LAST_FULL_MARKER="${BACKUP_OUTPUT_DIR:-/backups}/.last_full_backup"

# ===========================================================================
# Section 1 — Physical hot backup (mariadb-backup)
# ===========================================================================
log "Starting physical backup (mode: ${MARIADB_BACKUP_MODE})..."

# ---------------------------------------------------------------------------
# Incremental path
# ---------------------------------------------------------------------------
if [[ "${MARIADB_BACKUP_MODE}" == "incremental" ]] && [[ -f "${LAST_FULL_MARKER}" ]]; then
  LAST_FULL="$(cat "${LAST_FULL_MARKER}")"

  if [[ -d "${LAST_FULL}" ]]; then
    log "Incremental backup based on full at: ${LAST_FULL}"
    mkdir -p "${INCR_BACKUP_DIR}"

    # --incremental-basedir: path to the previous full (or incremental) backup.
    # mariadb-backup reads the LSN (Log Sequence Number) from the basedir and
    # only copies InnoDB pages whose LSN is higher — drastically reducing the
    # amount of data written for frequent incremental runs.
    mariadb-backup --backup \
      "${MARIADB_ARGS[@]}" \
      --target-dir="${INCR_BACKUP_DIR}" \
      --incremental-basedir="${LAST_FULL}" \
      2>&1 | while IFS= read -r line; do log "[mbk] ${line}"; done
      # Pipe mariadb-backup's stderr/stdout through the log() prefix so all
      # output appears in journald with consistent timestamps and prefixes.

    PHYSICAL_DIR="${INCR_BACKUP_DIR}"

  else
    # The marker file references a path that no longer exists (e.g. manually
    # cleaned up, or a different host).  Safely fall back to full backup.
    log "WARNING: last full backup at '${LAST_FULL}' does not exist — falling back to full."
    MARIADB_BACKUP_MODE="full"
  fi
fi

# ---------------------------------------------------------------------------
# Full backup path (also reached when incremental falls back)
# ---------------------------------------------------------------------------
if [[ "${MARIADB_BACKUP_MODE}" == "full" ]]; then
  log "Performing full physical backup..."
  mkdir -p "${FULL_BACKUP_BASE}"

  mariadb-backup --backup \
    "${MARIADB_ARGS[@]}" \
    --target-dir="${FULL_BACKUP_BASE}" \
    2>&1 | while IFS= read -r line; do log "[mbk] ${line}"; done

  # Update the marker so the next incremental run knows where this full is.
  echo "${FULL_BACKUP_BASE}" > "${LAST_FULL_MARKER}"
  log "Updated .last_full_backup marker → ${FULL_BACKUP_BASE}"

  PHYSICAL_DIR="${FULL_BACKUP_BASE}"
fi

# ---------------------------------------------------------------------------
# Compress the physical backup directory into a single tarball
#
# Why compress after backup rather than using --stream=xbstream?
#   Using --stream would require piping through mbstream and adds complexity
#   for incremental restores.  Instead we let mariadb-backup write its native
#   directory layout, then tar+gzip it.  This preserves the directory structure
#   that --prepare and --copy-back expect during restore.
#
# tar flags:
#   -c  : create archive
#   -z  : gzip compression
#   -f  : output file
#   -C  : change to parent directory first (so the archive root is the
#         backup dir name, not an absolute path)
#   $(basename "${PHYSICAL_DIR}") : relative dir name inside the archive
#
# The uncompressed directory is removed after archiving to free space.
# ---------------------------------------------------------------------------
PHYSICAL_ARCHIVE="${RUN_DIR}/mariadb-backup-${MARIADB_BACKUP_MODE}.tar.gz"
log "Compressing physical backup to ${PHYSICAL_ARCHIVE}..."
tar -czf "${PHYSICAL_ARCHIVE}" \
  -C "$(dirname "${PHYSICAL_DIR}")" \
  "$(basename "${PHYSICAL_DIR}")"

# Remove the now-archived raw directory to keep disk usage minimal.
rm -rf "${PHYSICAL_DIR}"
log "Removed raw backup directory: ${PHYSICAL_DIR}"

# Register the archive file in the tracking DB.
FILE_ID="$(db_record_file "${RUN_ID}" "${PHYSICAL_ARCHIVE}" "mariadb-backup")"
log "Recorded physical backup file: ID=${FILE_ID}"

# ===========================================================================
# Section 2 — Logical SQL dump (mariadb-dump)
# ===========================================================================
DUMP_FILE="${RUN_DIR}/mariadb-dump-all.sql.gz"
log "Starting logical dump → ${DUMP_FILE}..."

mariadb-dump \
  --host="${MARIADB_HOST}" \
  --port="${MARIADB_PORT}" \
  --user="${MARIADB_USER}" \
  --password="${MARIADB_PASSWORD}" \
  --all-databases \
  \
  # --single-transaction: wraps all tables in a single READ COMMITTED
  # transaction so we get a consistent snapshot without locking any rows.
  # This is the correct option for InnoDB tables and avoids blocking writes.
  --single-transaction \
  \
  # --quick: fetches rows one at a time rather than buffering the entire
  # result set in memory.  Essential for large tables (prevents OOM).
  --quick \
  \
  # --lock-tables=false: must be explicitly disabled because mariadb-dump
  # enables it by default for non-transactional tables (MyISAM).  Combined
  # with --single-transaction, this gives a consistent InnoDB dump with no
  # table locks at all.  If the target has MyISAM tables, add --lock-tables
  # back and accept the brief read lock.
  --lock-tables=false \
  \
  # --routines: include stored procedures and functions in the dump.
  # --triggers: include trigger definitions.
  # --events: include scheduled event definitions.
  # These are excluded by default but are needed for a complete restore.
  --routines \
  --triggers \
  --events \
  \
  # --comments: include version and dump-time comments at the top of the file.
  # Useful for auditing which MariaDB version produced this dump.
  --comments \
  \
  # --gtid-current-pos: add a SET @@gtid_current_pos statement at the top of
  # the dump.  This records the current GTID position at the time of the dump
  # so that replication can be set up from this backup without a gap.
  # Harmless if GTIDs are not in use.
  --gtid-current-pos \
  2>/dev/null \
  | gzip > "${DUMP_FILE}"
# stderr is redirected to /dev/null to suppress the "Warning: Using a password
# on the command line is insecure" message — the password is in the env, not
# in a --password= flag visible via `ps`, but MariaDB still warns.

FILE_ID="$(db_record_file "${RUN_ID}" "${DUMP_FILE}" "dump")"
log "Recorded dump file: ID=${FILE_ID}"

log "MariaDB backup complete (physical + logical)."
