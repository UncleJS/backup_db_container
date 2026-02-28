#!/usr/bin/env bash
# =============================================================================
# bin/install.sh — First-time installation
#
# What it does:
#   1. Detects (or prompts for) your numeric UID
#   2. Builds all four container images
#   3. Creates the Podman named volume and host backup directory
#   4. Installs Quadlet unit files (with @@UID@@ substituted)
#   5. Reloads systemd and enables the pod + timer
#   6. Optionally walks you through creating Podman secrets
#
# Usage:
#   ./bin/install.sh                  # interactive
#   ./bin/install.sh --uid 1001       # non-interactive UID override
#   ./bin/install.sh --skip-secrets   # skip the secrets wizard
#   ./bin/install.sh --skip-build     # skip image builds (re-use existing)
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUADLET_DIR="${HOME}/.config/containers/systemd"
BACKUP_HOST_DIR="${HOME}/.local/share/backup-agent/backups"

# --- colour helpers ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[install]${RESET} $*"; }
success() { echo -e "${GREEN}[install]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[install]${RESET} $*"; }
die()     { echo -e "${RED}[install] ERROR:${RESET} $*" >&2; exit 1; }

# --- parse arguments ---------------------------------------------------------
ARG_UID=""
SKIP_SECRETS=false
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uid)        ARG_UID="$2"; shift 2 ;;
    --skip-secrets) SKIP_SECRETS=true; shift ;;
    --skip-build)   SKIP_BUILD=true;   shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# =============================================================================
# STEP 1 — Determine UID
# =============================================================================
echo ""
echo -e "${BOLD}=== backup_db_container installer ===${RESET}"
echo ""

if [[ -n "${ARG_UID}" ]]; then
  INSTALL_UID="${ARG_UID}"
  info "Using UID from --uid flag: ${INSTALL_UID}"
else
  DETECTED_UID="$(id -u)"
  info "Detected current user UID: ${DETECTED_UID}"
  read -r -p "$(echo -e "  Use UID [${DETECTED_UID}] for Podman socket path? (Enter to accept, or type a different UID): ")" INPUT_UID
  INSTALL_UID="${INPUT_UID:-${DETECTED_UID}}"
fi

[[ "${INSTALL_UID}" =~ ^[0-9]+$ ]] || die "UID must be a positive integer, got: '${INSTALL_UID}'"
success "Installing with UID=${INSTALL_UID}"

# =============================================================================
# STEP 2 — Build images
# =============================================================================
if [[ "${SKIP_BUILD}" == "true" ]]; then
  warn "Skipping image builds (--skip-build)."
else
  echo ""
  info "Building container images…"

  info "  [1/4] backup-agent"
  podman build --quiet -f "${REPO_DIR}/Containerfile.agent" \
    -t localhost/backup-agent:latest "${REPO_DIR}"

  info "  [2/4] backup-tracking-db"
  podman build --quiet -f "${REPO_DIR}/tracking-db/Containerfile.tracking-db" \
    -t localhost/backup-tracking-db:latest "${REPO_DIR}/tracking-db"

  info "  [3/4] backup-api"
  podman build --quiet -f "${REPO_DIR}/api/Containerfile.api" \
    -t localhost/backup-api:latest "${REPO_DIR}/api"

  info "  [4/4] backup-dashboard"
  podman build --quiet -f "${REPO_DIR}/dashboard/Containerfile.dashboard" \
    -t localhost/backup-dashboard:latest "${REPO_DIR}/dashboard"

  success "All images built."
fi

# =============================================================================
# STEP 3 — Create Podman named volume + host backup dir
# =============================================================================
echo ""
info "Creating Podman named volume 'tracking-data'…"
podman volume exists tracking-data 2>/dev/null \
  && warn "  Volume 'tracking-data' already exists — skipping." \
  || podman volume create tracking-data

info "Creating host backup directory: ${BACKUP_HOST_DIR}"
mkdir -p "${BACKUP_HOST_DIR}"
chmod 0700 "${BACKUP_HOST_DIR}"
success "Storage ready."

# =============================================================================
# STEP 4 — Install Quadlet units (with @@UID@@ substituted)
# =============================================================================
echo ""
info "Installing Quadlet unit files to ${QUADLET_DIR}…"
mkdir -p "${QUADLET_DIR}"

QUADLET_SRC="${REPO_DIR}/quadlet"

for src_file in "${QUADLET_SRC}"/*.pod "${QUADLET_SRC}"/*.container \
                "${QUADLET_SRC}"/*.timer "${QUADLET_SRC}"/*.service; do
  [[ -f "${src_file}" ]] || continue
  dest_file="${QUADLET_DIR}/$(basename "${src_file}")"
  # Substitute @@UID@@ placeholder
  sed "s/@@UID@@/${INSTALL_UID}/g" "${src_file}" > "${dest_file}"
  info "  → $(basename "${dest_file}")"
done

# Patch the backup host dir into the agent container unit
AGENT_UNIT="${QUADLET_DIR}/backup-agent.container"
sed -i "s|Volume=/var/lib/backup-agent/backups:/backups:z|Volume=${BACKUP_HOST_DIR}:/backups:z|g" \
  "${AGENT_UNIT}"

success "Quadlet units installed."

# =============================================================================
# STEP 5 — Reload systemd, enable pod + timer
# =============================================================================
echo ""
info "Reloading systemd user daemon…"
systemctl --user daemon-reload

info "Enabling backup-pod.service…"
systemctl --user enable backup-pod.service

info "Enabling backup-agent.timer…"
systemctl --user enable backup-agent.timer

success "Systemd units enabled."

# =============================================================================
# STEP 6 — Optional secrets wizard
# =============================================================================
if [[ "${SKIP_SECRETS}" == "true" ]]; then
  warn "Skipping secrets wizard (--skip-secrets)."
  warn "Run  ./bin/secrets.sh  to create secrets before starting the pod."
else
  echo ""
  echo -e "${BOLD}--- Secrets setup ---${RESET}"
  echo "The following Podman secrets are required. You will be prompted for each."
  echo "Press Enter to skip any secret you've already created."
  echo ""

  create_secret_if_missing() {
    local name="$1"
    local prompt="$2"
    local is_file="${3:-false}"

    if podman secret inspect "${name}" &>/dev/null 2>&1; then
      warn "  Secret '${name}' already exists — skipping."
      return
    fi

    if [[ "${is_file}" == "true" ]]; then
      read -r -p "  ${prompt} (path to file, or Enter to skip): " val
      [[ -z "${val}" ]] && { warn "  Skipped '${name}'."; return; }
      [[ -f "${val}" ]] || { warn "  File not found, skipping '${name}'."; return; }
      podman secret create "${name}" "${val}"
    else
      read -r -s -p "  ${prompt} (Enter to skip): " val
      echo ""
      [[ -z "${val}" ]] && { warn "  Skipped '${name}'."; return; }
      printf '%s' "${val}" | podman secret create "${name}" -
    fi
    success "  Created secret '${name}'."
  }

  create_secret_if_missing "tracking_db_root_password" \
    "Tracking DB ROOT password"
  create_secret_if_missing "tracking_db_password" \
    "Tracking DB API user password"
  create_secret_if_missing "mariadb_backup_password" \
    "Source MariaDB backup user password"
  create_secret_if_missing "internal_api_secret" \
    "Internal API secret (or press Enter to auto-generate)"

  # Auto-generate internal_api_secret if still missing
  if ! podman secret inspect internal_api_secret &>/dev/null 2>&1; then
    GEN=$(openssl rand -hex 32)
    printf '%s' "${GEN}" | podman secret create internal_api_secret -
    success "  Auto-generated secret 'internal_api_secret'."
  fi

  create_secret_if_missing "dashboard_session_secret" \
    "Dashboard session signing secret (or press Enter to auto-generate)"

  if ! podman secret inspect dashboard_session_secret &>/dev/null 2>&1; then
    GEN=$(openssl rand -hex 32)
    printf '%s' "${GEN}" | podman secret create dashboard_session_secret -
    success "  Auto-generated secret 'dashboard_session_secret'."
  fi

  create_secret_if_missing "dashboard_admin_password" \
    "Dashboard admin password"

  echo ""
  echo -e "${YELLOW}Optional secrets (S3 / SFTP — skip if not using):${RESET}"
  create_secret_if_missing "s3_secret_key"      "S3 secret access key"
  create_secret_if_missing "sftp_password"      "SFTP password"
  create_secret_if_missing "sftp_private_key"   "SFTP private key" true
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}Installation complete!${RESET}"
echo ""
echo -e "  Start the pod :  ${CYAN}./bin/start.sh${RESET}"
echo -e "  Check status  :  ${CYAN}./bin/status.sh${RESET}"
echo -e "  View logs     :  ${CYAN}./bin/logs.sh${RESET}"
echo -e "  Run backup    :  ${CYAN}./bin/backup-now.sh${RESET}"
echo ""
echo -e "  Dashboard     :  ${CYAN}http://localhost:3000${RESET}"
echo -e "  API / Swagger :  ${CYAN}http://localhost:3001/swagger${RESET}"
echo ""
