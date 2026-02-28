#!/usr/bin/env bash
# =============================================================================
# bin/uninstall.sh — Remove the backup_db_container installation
#
# Usage:
#   ./bin/uninstall.sh                  # stops services, removes Quadlet units
#   ./bin/uninstall.sh --purge-volumes  # also deletes tracking-data volume (DATA LOSS)
#   ./bin/uninstall.sh --purge-images   # also removes built container images
#   ./bin/uninstall.sh --purge-secrets  # also removes all Podman secrets
#   ./bin/uninstall.sh --purge-all      # everything above
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[uninstall]${RESET} $*"; }
success() { echo -e "${GREEN}[uninstall]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[uninstall]${RESET} $*"; }
die()     { echo -e "${RED}[uninstall] ERROR:${RESET} $*" >&2; exit 1; }

PURGE_VOLUMES=false
PURGE_IMAGES=false
PURGE_SECRETS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-volumes) PURGE_VOLUMES=true; shift ;;
    --purge-images)  PURGE_IMAGES=true;  shift ;;
    --purge-secrets) PURGE_SECRETS=true; shift ;;
    --purge-all)
      PURGE_VOLUMES=true; PURGE_IMAGES=true; PURGE_SECRETS=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

QUADLET_DIR="${HOME}/.config/containers/systemd"

SERVICES=(
  backup-agent.timer
  backup-agent.service
  backup-dashboard.service
  backup-api.service
  backup-tracking-db.service
  backup-pod.service
)

UNITS=(
  backup-pod.pod
  backup-tracking-db.container
  backup-api.container
  backup-dashboard.container
  backup-agent.container
  backup-agent.timer
  backup-agent.service
)

IMAGES=(
  localhost/backup-agent:latest
  localhost/backup-tracking-db:latest
  localhost/backup-api:latest
  localhost/backup-dashboard:latest
)

SECRETS=(
  mariadb_backup_password
  tracking_db_password
  tracking_db_root_password
  s3_secret_key
  sftp_password
  sftp_private_key
  internal_api_secret
  dashboard_session_secret
  dashboard_admin_password
)

# --- Confirmation prompt for destructive flags --------------------------------
if [[ "${PURGE_VOLUMES}" == "true" || "${PURGE_SECRETS}" == "true" ]]; then
  echo ""
  echo -e "${RED}${BOLD}WARNING: Destructive options selected.${RESET}"
  [[ "${PURGE_VOLUMES}" == "true" ]] && \
    echo -e "  ${RED}--purge-volumes${RESET}: The 'tracking-data' volume will be DELETED (backup history lost)."
  [[ "${PURGE_SECRETS}" == "true" ]] && \
    echo -e "  ${RED}--purge-secrets${RESET}: All Podman secrets will be DELETED (passwords, keys lost)."
  echo ""
  read -r -p "Type 'yes' to confirm: " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || { warn "Aborted."; exit 0; }
fi

# --- 1. Stop and disable services ---------------------------------------------
echo ""
info "Stopping services…"
for svc in "${SERVICES[@]}"; do
  if systemctl --user is-active --quiet "${svc}" 2>/dev/null; then
    systemctl --user stop "${svc}" && info "  Stopped ${svc}"
  fi
  if systemctl --user is-enabled --quiet "${svc}" 2>/dev/null; then
    systemctl --user disable "${svc}" 2>/dev/null && info "  Disabled ${svc}"
  fi
done
success "Services stopped."

# --- 2. Remove Quadlet unit files --------------------------------------------
echo ""
info "Removing Quadlet unit files from ${QUADLET_DIR}…"
for unit in "${UNITS[@]}"; do
  f="${QUADLET_DIR}/${unit}"
  if [[ -f "${f}" ]]; then
    rm "${f}"
    info "  Removed ${unit}"
  fi
done

systemctl --user daemon-reload
success "Quadlet units removed."

# --- 3. Purge volumes (optional) ---------------------------------------------
if [[ "${PURGE_VOLUMES}" == "true" ]]; then
  echo ""
  info "Removing Podman volume 'tracking-data'…"
  podman volume rm tracking-data 2>/dev/null && success "  Volume deleted." \
    || warn "  Volume not found or already removed."
fi

# --- 4. Purge images (optional) ----------------------------------------------
if [[ "${PURGE_IMAGES}" == "true" ]]; then
  echo ""
  info "Removing container images…"
  for img in "${IMAGES[@]}"; do
    podman image rm "${img}" 2>/dev/null && info "  Removed ${img}" \
      || warn "  Image not found: ${img}"
  done
  success "Images removed."
fi

# --- 5. Purge secrets (optional) ---------------------------------------------
if [[ "${PURGE_SECRETS}" == "true" ]]; then
  echo ""
  info "Removing Podman secrets…"
  for secret in "${SECRETS[@]}"; do
    podman secret rm "${secret}" 2>/dev/null && info "  Removed secret '${secret}'" \
      || warn "  Secret not found: '${secret}'"
  done
  success "Secrets removed."
fi

# --- Done ---------------------------------------------------------------------
echo ""
success "Uninstall complete."
if [[ "${PURGE_VOLUMES}" == "false" ]]; then
  warn "Backup history (tracking-data volume) and host backup files were preserved."
  warn "To remove them, re-run with:  ./bin/uninstall.sh --purge-volumes --purge-secrets"
fi
echo ""
