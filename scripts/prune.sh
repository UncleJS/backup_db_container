#!/usr/bin/env bash
# =============================================================================
# prune.sh — Remove backup run directories older than RETENTION_DAYS
# Logs each deleted path to the tracking DB via db_record_retention.
# Args: <backup_output_dir> <retention_days> <api_url> <api_secret>
# =============================================================================
set -euo pipefail

BACKUP_OUTPUT_DIR="$1"
RETENTION_DAYS="$2"
API_BASE_URL="$3"
INTERNAL_API_SECRET="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/db_record.sh"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [prune] $*"; }

log "Pruning backups older than ${RETENTION_DAYS} days in ${BACKUP_OUTPUT_DIR}..."

PRUNED=0
# Cutoff epoch: any run whose timestamp is earlier than this should be pruned.
CUTOFF_EPOCH=$(( $(date -u +%s) - RETENTION_DAYS * 86400 ))

# Find run directories named YYYY-MM-DD_HH-MM-SS and decide by their embedded
# timestamp — NOT by inode mtime which changes whenever files inside are written.
while IFS= read -r dir; do
  [[ -z "${dir}" ]] && continue

  # Extract the YYYY-MM-DD_HH-MM-SS stamp from the directory basename.
  BASENAME="$(basename "${dir}")"
  # Convert YYYY-MM-DD_HH-MM-SS → YYYY-MM-DD HH:MM:SS for `date`
  DIR_TS="${BASENAME//_/ }"          # replace first _ (date/time separator)
  DIR_TS="${DIR_TS//-/:}"            # replace - separators (careful: date part uses -)
  # More precise: replace only the time-part dashes; use a targeted sed-free approach:
  # Format: 2026-02-28_14-30-00 → date -d "2026-02-28 14:30:00"
  DATE_PART="${BASENAME%%_*}"        # 2026-02-28
  TIME_PART="${BASENAME##*_}"        # 14-30-00
  TIME_PART="${TIME_PART//-/:}"      # 14:30:00
  DIR_EPOCH="$(date -u -d "${DATE_PART} ${TIME_PART}" +%s 2>/dev/null || echo 0)"

  if [[ "${DIR_EPOCH}" -eq 0 ]] || [[ "${DIR_EPOCH}" -gt "${CUTOFF_EPOCH}" ]]; then
    # Could not parse timestamp or directory is within retention window — skip.
    continue
  fi

  DIR_SIZE="$(du -sb "${dir}" 2>/dev/null | awk '{print $1}' || echo 0)"
  log "Deleting: ${dir} (${DIR_SIZE} bytes)"

  # Record each file within before deleting
  while IFS= read -r filepath; do
    FILE_SIZE="$(stat -c%s "${filepath}" 2>/dev/null || echo 0)"
    db_record_retention "${filepath}" "${FILE_SIZE}" "${RETENTION_DAYS}" || true
  done < <(find "${dir}" -maxdepth 1 -type f 2>/dev/null)

  rm -rf "${dir}"
  PRUNED=$((PRUNED + 1))
done < <(find "${BACKUP_OUTPUT_DIR}" -maxdepth 1 -mindepth 1 -type d \
           -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*' 2>/dev/null)

# Also remove orphaned .last_full_backup marker if the target dir no longer exists
LAST_FULL_MARKER="${BACKUP_OUTPUT_DIR}/.last_full_backup"
if [[ -f "${LAST_FULL_MARKER}" ]]; then
  LAST_FULL="$(cat "${LAST_FULL_MARKER}")"
  if [[ ! -d "${LAST_FULL}" ]]; then
    log "Removing stale .last_full_backup marker (target gone: ${LAST_FULL})"
    rm -f "${LAST_FULL_MARKER}"
  fi
fi

log "Pruning complete. Removed ${PRUNED} run director(ies)."
