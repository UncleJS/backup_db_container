#!/usr/bin/env bash
# =============================================================================
# backup_configs.sh — Export Podman pod/container inspect JSON + unit files
# Args: <run_dir> <api_url> <run_id> <api_secret>
# Env:  PODMAN_SOCKET (default: /run/podman/podman.sock)
#       QUADLET_DIRS  (colon-sep; default: ~/.config/containers/systemd)
# =============================================================================
set -euo pipefail

RUN_DIR="$1"
API_BASE_URL="$2"
RUN_ID="$3"
INTERNAL_API_SECRET="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/db_record.sh"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [configs] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [configs][ERROR] $*" >&2; }

PODMAN_SOCKET="${PODMAN_SOCKET:-/run/podman/podman.sock}"
CONFIGS_WORK_DIR="${RUN_DIR}/configs-work"
ARCHIVE="${RUN_DIR}/configs.tar.gz"

mkdir -p "${CONFIGS_WORK_DIR}/inspect" "${CONFIGS_WORK_DIR}/units"

podman_api() {
  curl -sf --unix-socket "${PODMAN_SOCKET}" "http://d/v4.0.0/libpod$1"
}

# -----------------------------------------------------------------------
# 1. Pod inspect
# -----------------------------------------------------------------------
if [[ -S "${PODMAN_SOCKET}" ]]; then
  log "Exporting pod inspect data..."
  PODS_JSON="$(podman_api "/pods/json" 2>/dev/null || echo "[]")"
  echo "${PODS_JSON}" > "${CONFIGS_WORK_DIR}/inspect/pods.json"

  # Per-pod inspect
  POD_IDS="$(echo "${PODS_JSON}" | jq -r '.[].Id // .[].ID // empty')"
  while IFS= read -r pod_id; do
    [[ -z "${pod_id}" ]] && continue
    podman_api "/pods/${pod_id}/json" 2>/dev/null \
      > "${CONFIGS_WORK_DIR}/inspect/pod-${pod_id:0:12}.json" || true
  done <<< "${POD_IDS}"

  # -----------------------------------------------------------------------
  # 2. Container inspect
  # -----------------------------------------------------------------------
  log "Exporting container inspect data..."
  CONTAINERS_JSON="$(podman_api "/containers/json?all=true" 2>/dev/null || echo "[]")"
  echo "${CONTAINERS_JSON}" > "${CONFIGS_WORK_DIR}/inspect/containers.json"

  CONTAINER_IDS="$(echo "${CONTAINERS_JSON}" | jq -r '.[].Id // .[].ID // empty')"
  while IFS= read -r cid; do
    [[ -z "${cid}" ]] && continue
    CNAME="$(echo "${CONTAINERS_JSON}" | jq -r --arg id "${cid}" '.[] | select(.Id==$id or .ID==$id) | .Names[0] // .Name // $id' | head -1)"
    SAFE_NAME="$(echo "${CNAME}" | tr '/' '_' | tr -d ' ')"
    podman_api "/containers/${cid}/json" 2>/dev/null \
      > "${CONFIGS_WORK_DIR}/inspect/container-${SAFE_NAME:-${cid:0:12}}.json" || true
  done <<< "${CONTAINER_IDS}"
else
  err "Podman socket not found — skipping inspect export."
fi

# -----------------------------------------------------------------------
# 3. Quadlet / systemd unit files
# -----------------------------------------------------------------------
log "Exporting systemd unit files..."

# Default Quadlet dirs to search
IFS=':' read -ra UNIT_DIRS <<< "${QUADLET_DIRS:-${HOME}/.config/containers/systemd:${HOME}/.config/systemd/user:/etc/containers/systemd}"

for unit_dir in "${UNIT_DIRS[@]}"; do
  if [[ -d "${unit_dir}" ]]; then
    SAFE_DIR="$(echo "${unit_dir}" | tr '/' '_' | sed 's/^_//')"
    DEST="${CONFIGS_WORK_DIR}/units/${SAFE_DIR}"
    mkdir -p "${DEST}"
    # Copy .container .pod .volume .network .timer .service files
    find "${unit_dir}" -maxdepth 2 \
      \( -name "*.container" -o -name "*.pod" -o -name "*.volume" \
         -o -name "*.network" -o -name "*.timer" -o -name "*.service" \) \
      -exec cp {} "${DEST}/" \; 2>/dev/null || true
    log "  Collected units from ${unit_dir}"
  fi
done

# Also export any user-level .env files referenced by units (non-secret)
# (users should keep secrets out of env files; we copy only .env.example patterns)

# -----------------------------------------------------------------------
# 4. Write metadata manifest
# -----------------------------------------------------------------------
cat > "${CONFIGS_WORK_DIR}/manifest.json" <<EOF
{
  "exported_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "podman_socket": "${PODMAN_SOCKET}",
  "quadlet_dirs": "${QUADLET_DIRS:-default}"
}
EOF

# -----------------------------------------------------------------------
# 5. Compress and record
# -----------------------------------------------------------------------
log "Compressing config archive → ${ARCHIVE}"
tar -czf "${ARCHIVE}" -C "${RUN_DIR}" "configs-work"
rm -rf "${CONFIGS_WORK_DIR}"

FILE_ID="$(db_record_file "${RUN_ID}" "${ARCHIVE}" "config")"
log "Recorded config backup: ID=${FILE_ID}"
log "Config backup complete."
