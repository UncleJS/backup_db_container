#!/usr/bin/env bash
# =============================================================================
# backup_volumes.sh — Backup Podman named volumes via the Podman socket
# Args: <run_dir> <api_url> <run_id> <api_secret>
# Env:  PODMAN_VOLUMES (comma-sep list; empty = all)
#       PODMAN_SOCKET  (default: /run/podman/podman.sock)
# =============================================================================
set -euo pipefail

RUN_DIR="$1"
API_BASE_URL="$2"
RUN_ID="$3"
INTERNAL_API_SECRET="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/db_record.sh"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [volumes] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [volumes][ERROR] $*" >&2; }

PODMAN_SOCKET="${PODMAN_SOCKET:-/run/podman/podman.sock}"

if [[ ! -S "${PODMAN_SOCKET}" ]]; then
  err "Podman socket not found at ${PODMAN_SOCKET}. Is the socket bind-mounted?"
  exit 1
fi

podman_api() {
  curl -sf --unix-socket "${PODMAN_SOCKET}" "http://d/v4.0.0/libpod$1"
}

# -----------------------------------------------------------------------
# Determine which volumes to back up
# -----------------------------------------------------------------------
ALL_VOLUMES_JSON="$(podman_api "/volumes/json")"
ALL_VOLUME_NAMES="$(echo "${ALL_VOLUMES_JSON}" | jq -r '.[].Name')"

if [[ -n "${PODMAN_VOLUMES}" ]]; then
  IFS=',' read -ra REQUESTED <<< "${PODMAN_VOLUMES}"
  VOLUME_NAMES=()
  for v in "${REQUESTED[@]}"; do
    v="$(echo "${v}" | xargs)"  # trim whitespace
    if echo "${ALL_VOLUME_NAMES}" | grep -qx "${v}"; then
      VOLUME_NAMES+=("${v}")
    else
      err "Requested volume '${v}' not found — skipping."
    fi
  done
else
  mapfile -t VOLUME_NAMES <<< "${ALL_VOLUME_NAMES}"
fi

if [[ ${#VOLUME_NAMES[@]} -eq 0 ]]; then
  log "No volumes to back up."
  exit 0
fi

log "Volumes to back up: ${VOLUME_NAMES[*]}"

# -----------------------------------------------------------------------
# Back up each volume
# -----------------------------------------------------------------------
for VOL_NAME in "${VOLUME_NAMES[@]}"; do
  [[ -z "${VOL_NAME}" ]] && continue

  # Get the mountpoint of this volume
  VOL_INFO="$(podman_api "/volumes/${VOL_NAME}")"
  VOL_MOUNTPOINT="$(echo "${VOL_INFO}" | jq -r '.Mountpoint')"

  if [[ -z "${VOL_MOUNTPOINT}" ]] || [[ ! -d "${VOL_MOUNTPOINT}" ]]; then
    err "Cannot determine mountpoint for volume '${VOL_NAME}' (got: '${VOL_MOUNTPOINT}'). Skipping."
    continue
  fi

  ARCHIVE="${RUN_DIR}/volume-${VOL_NAME}.tar.gz"
  log "Backing up volume '${VOL_NAME}' from ${VOL_MOUNTPOINT} → ${ARCHIVE}"

  tar -czf "${ARCHIVE}" -C "${VOL_MOUNTPOINT}" . 2>/dev/null || {
    err "tar failed for volume '${VOL_NAME}'"
    continue
  }

  FILE_ID="$(db_record_file "${RUN_ID}" "${ARCHIVE}" "volume")"
  log "Recorded volume backup: ${VOL_NAME} ID=${FILE_ID}"
done

log "Volume backup complete."
