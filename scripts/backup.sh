#!/usr/bin/env bash
# =============================================================================
# backup.sh — Main orchestrator entrypoint
# Runs inside the backup-agent container.
# Reads secrets from /run/secrets/, env vars from the environment,
# orchestrates all backup steps, records results to the tracking API.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/db_record.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [INFO]  $*"; }
warn() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [WARN]  $*" >&2; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [ERROR] $*" >&2; }

read_secret() {
  local name="$1"
  local path="/run/secrets/${name}"
  if [[ -f "${path}" ]]; then
    cat "${path}"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Load secrets
# ---------------------------------------------------------------------------
MARIADB_PASSWORD="$(read_secret mariadb_backup_password)"
TRACKING_DB_PASSWORD="$(read_secret tracking_db_password)"
S3_SECRET_KEY="$(read_secret s3_secret_key)"
SFTP_PASSWORD="$(read_secret sftp_password)"
# sftp_private_key is read directly by upload_sftp.sh via KEY_PEM

# ---------------------------------------------------------------------------
# Defaults / environment
# ---------------------------------------------------------------------------
BACKUP_OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-/backups}"
MARIADB_HOST="${MARIADB_HOST:-127.0.0.1}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_USER="${MARIADB_USER:-backup_user}"
MARIADB_BACKUP_MODE="${MARIADB_BACKUP_MODE:-full}"   # full | incremental

BACKUP_MARIADB="${BACKUP_MARIADB:-true}"
BACKUP_VOLUMES="${BACKUP_VOLUMES:-true}"
BACKUP_CONFIGS="${BACKUP_CONFIGS:-true}"
PODMAN_VOLUMES="${PODMAN_VOLUMES:-}"                 # comma-sep; empty = all

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

S3_ENABLED="${S3_ENABLED:-false}"
SFTP_ENABLED="${SFTP_ENABLED:-false}"

API_BASE_URL="${API_BASE_URL:-http://localhost:3001}"
INTERNAL_API_SECRET="$(read_secret internal_api_secret)"

TRIGGER_TYPE="${TRIGGER_TYPE:-scheduled}"            # scheduled | manual

# Timestamp for this run
RUN_TS="$(date -u '+%Y-%m-%d_%H-%M-%S')"
RUN_DIR="${BACKUP_OUTPUT_DIR}/${RUN_TS}"

# ---------------------------------------------------------------------------
# Check for manual trigger signal
# ---------------------------------------------------------------------------
if [[ -f /tmp/backup-trigger ]]; then
  TRIGGER_TYPE="manual"
  rm -f /tmp/backup-trigger
  log "Manual trigger detected."
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
mkdir -p "${RUN_DIR}"
log "=== Backup run started: ${RUN_TS} (trigger: ${TRIGGER_TYPE}) ==="

# Register run in tracking DB
RUN_ID="$(db_create_run "${TRIGGER_TYPE}" "${MARIADB_BACKUP_MODE}")"
log "Tracking run ID: ${RUN_ID}"

OVERALL_STATUS="success"
TOTAL_SIZE=0
ERRORS=()

# ---------------------------------------------------------------------------
# Step 1 — MariaDB backup
# ---------------------------------------------------------------------------
if [[ "${BACKUP_MARIADB}" == "true" ]]; then
  log "--- MariaDB backup ---"
  if MARIADB_PASSWORD="${MARIADB_PASSWORD}" \
     "${SCRIPT_DIR}/backup_mariadb.sh" \
       "${RUN_DIR}" "${MARIADB_HOST}" "${MARIADB_PORT}" \
       "${MARIADB_USER}" "${MARIADB_BACKUP_MODE}" \
       "${API_BASE_URL}" "${RUN_ID}" "${INTERNAL_API_SECRET}"; then
    log "MariaDB backup completed."
  else
    err "MariaDB backup FAILED."
    ERRORS+=("mariadb")
    OVERALL_STATUS="partial"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — Podman volume backup
# ---------------------------------------------------------------------------
if [[ "${BACKUP_VOLUMES}" == "true" ]]; then
  log "--- Podman volumes backup ---"
  if PODMAN_VOLUMES="${PODMAN_VOLUMES}" \
     "${SCRIPT_DIR}/backup_volumes.sh" \
       "${RUN_DIR}" "${API_BASE_URL}" "${RUN_ID}" "${INTERNAL_API_SECRET}"; then
    log "Volume backup completed."
  else
    err "Volume backup FAILED."
    ERRORS+=("volumes")
    OVERALL_STATUS="partial"
  fi
fi

# ---------------------------------------------------------------------------
# Step 3 — Podman container/pod config backup
# ---------------------------------------------------------------------------
if [[ "${BACKUP_CONFIGS}" == "true" ]]; then
  log "--- Podman configs backup ---"
  if "${SCRIPT_DIR}/backup_configs.sh" \
       "${RUN_DIR}" "${API_BASE_URL}" "${RUN_ID}" "${INTERNAL_API_SECRET}"; then
    log "Config backup completed."
  else
    err "Config backup FAILED."
    ERRORS+=("configs")
    OVERALL_STATUS="partial"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4 — S3 upload
# ---------------------------------------------------------------------------
if [[ "${S3_ENABLED}" == "true" ]]; then
  log "--- S3 upload ---"
  if S3_SECRET_KEY="${S3_SECRET_KEY}" \
     "${SCRIPT_DIR}/upload_s3.sh" \
       "${RUN_DIR}" "${RUN_TS}" "${API_BASE_URL}" "${RUN_ID}" "${INTERNAL_API_SECRET}"; then
    log "S3 upload completed."
  else
    err "S3 upload FAILED."
    ERRORS+=("s3_upload")
    [[ "${OVERALL_STATUS}" == "success" ]] && OVERALL_STATUS="partial"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5 — SFTP upload
# ---------------------------------------------------------------------------
if [[ "${SFTP_ENABLED}" == "true" ]]; then
  log "--- SFTP upload ---"
  if SFTP_PASSWORD="${SFTP_PASSWORD}" \
     "${SCRIPT_DIR}/upload_sftp.sh" \
       "${RUN_DIR}" "${RUN_TS}" "${API_BASE_URL}" "${RUN_ID}" "${INTERNAL_API_SECRET}"; then
    log "SFTP upload completed."
  else
    err "SFTP upload FAILED."
    ERRORS+=("sftp_upload")
    [[ "${OVERALL_STATUS}" == "success" ]] && OVERALL_STATUS="partial"
  fi
fi

# ---------------------------------------------------------------------------
# Step 6 — Retention pruning
# ---------------------------------------------------------------------------
log "--- Retention pruning (keep ${BACKUP_RETENTION_DAYS} days) ---"
"${SCRIPT_DIR}/prune.sh" \
  "${BACKUP_OUTPUT_DIR}" "${BACKUP_RETENTION_DAYS}" \
  "${API_BASE_URL}" "${INTERNAL_API_SECRET}" || true

# ---------------------------------------------------------------------------
# Step 7 — Calculate total size and finalise run record
# ---------------------------------------------------------------------------
if [[ -d "${RUN_DIR}" ]]; then
  TOTAL_SIZE="$(du -sb "${RUN_DIR}" 2>/dev/null | awk '{print $1}' || echo 0)"
fi

ERROR_MSG=""
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  ERROR_MSG="Failed steps: $(IFS=,; echo "${ERRORS[*]}")"
  OVERALL_STATUS="failed"
fi

db_complete_run "${RUN_ID}" "${OVERALL_STATUS}" "${TOTAL_SIZE}" "${ERROR_MSG}"

log "=== Backup run finished: status=${OVERALL_STATUS} size=${TOTAL_SIZE}B ==="
[[ "${OVERALL_STATUS}" == "failed" ]] && exit 1 || exit 0
