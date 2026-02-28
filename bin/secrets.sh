#!/usr/bin/env bash
# =============================================================================
# bin/secrets.sh — Manage Podman secrets for backup_db_container
#
# Usage:
#   ./bin/secrets.sh list              # show all backup secrets and their state
#   ./bin/secrets.sh create            # interactive wizard to create missing secrets
#   ./bin/secrets.sh rotate <name>     # replace a specific secret
#   ./bin/secrets.sh rotate-auto       # auto-rotate internal_api_secret + session_secret
#   ./bin/secrets.sh delete <name>     # remove a specific secret (prompts confirm)
#   ./bin/secrets.sh delete-all        # remove ALL backup secrets (prompts confirm)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[secrets]${RESET} $*"; }
success() { echo -e "${GREEN}[secrets]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[secrets]${RESET} $*"; }
die()     { echo -e "${RED}[secrets] ERROR:${RESET} $*" >&2; exit 1; }

# All known secrets: name → description
declare -A SECRET_DESC=(
  [mariadb_backup_password]="Source MariaDB backup user password"
  [tracking_db_password]="Tracking DB API user password"
  [tracking_db_root_password]="Tracking DB root password"
  [s3_secret_key]="S3 secret access key (optional)"
  [sftp_password]="SFTP password (optional)"
  [sftp_private_key]="SFTP private key PEM file (optional)"
  [internal_api_secret]="Internal API shared secret (auto-generated)"
  [dashboard_session_secret]="Dashboard JWT session signing secret (auto-generated)"
  [dashboard_admin_password]="Dashboard admin login password"
)

REQUIRED_SECRETS=(
  tracking_db_root_password
  tracking_db_password
  mariadb_backup_password
  internal_api_secret
  dashboard_session_secret
  dashboard_admin_password
)

OPTIONAL_SECRETS=(
  s3_secret_key
  sftp_password
  sftp_private_key
)

secret_exists() {
  podman secret inspect "$1" &>/dev/null 2>&1
}

create_secret_interactive() {
  local name="$1"
  local desc="${SECRET_DESC[$name]:-$name}"
  local is_file="${2:-false}"
  local auto_gen="${3:-false}"

  echo ""
  echo -e "  ${BOLD}${name}${RESET} — ${DIM}${desc}${RESET}"

  if secret_exists "${name}"; then
    warn "  Already exists. Use  ./bin/secrets.sh rotate ${name}  to replace."
    return
  fi

  if [[ "${auto_gen}" == "true" ]]; then
    read -r -p "  Press Enter to auto-generate, or type a value: " val
    if [[ -z "${val}" ]]; then
      val="$(openssl rand -hex 32)"
      printf '%s' "${val}" | podman secret create "${name}" -
      success "  Auto-generated and stored '${name}'."
      return
    fi
    printf '%s' "${val}" | podman secret create "${name}" -
    success "  Stored '${name}'."
    return
  fi

  if [[ "${is_file}" == "true" ]]; then
    read -r -p "  Path to file (Enter to skip): " val
    [[ -z "${val}" ]] && { warn "  Skipped '${name}'."; return; }
    [[ -f "${val}" ]] || { warn "  File not found — skipped."; return; }
    podman secret create "${name}" "${val}"
  else
    read -r -s -p "  Value (Enter to skip): " val
    echo ""
    [[ -z "${val}" ]] && { warn "  Skipped '${name}'."; return; }
    printf '%s' "${val}" | podman secret create "${name}" -
  fi
  success "  Stored '${name}'."
}

cmd_list() {
  echo ""
  echo -e "${BOLD}=== Podman secrets ===${RESET}"
  echo ""
  printf "  %-35s %-10s %s\n" "Name" "Status" "Description"
  printf "  %-35s %-10s %s\n" "$(printf '%0.s-' {1..33})" "----------" "-----------"

  for name in "${REQUIRED_SECRETS[@]}" "${OPTIONAL_SECRETS[@]}"; do
    if secret_exists "${name}"; then
      status="${GREEN}✓ exists${RESET}"
    else
      # Optional secrets missing is fine
      if [[ " ${OPTIONAL_SECRETS[*]} " == *" ${name} "* ]]; then
        status="${DIM}— optional${RESET}"
      else
        status="${RED}✗ MISSING${RESET}"
      fi
    fi
    printf "  %-35s " "${name}"
    echo -e "${status}  ${DIM}${SECRET_DESC[$name]:-}${RESET}"
  done
  echo ""
}

cmd_create() {
  echo ""
  echo -e "${BOLD}=== Create missing secrets ===${RESET}"
  echo ""
  echo -e "${BOLD}Required:${RESET}"
  create_secret_interactive "tracking_db_root_password"
  create_secret_interactive "tracking_db_password"
  create_secret_interactive "mariadb_backup_password"
  create_secret_interactive "internal_api_secret"      "" true
  create_secret_interactive "dashboard_session_secret" "" true
  create_secret_interactive "dashboard_admin_password"

  echo ""
  echo -e "${BOLD}Optional (S3 / SFTP):${RESET}"
  create_secret_interactive "s3_secret_key"
  create_secret_interactive "sftp_password"
  create_secret_interactive "sftp_private_key" true

  echo ""
  success "Done. Run  ./bin/secrets.sh list  to verify."
}

cmd_rotate() {
  local name="${1:-}"
  [[ -z "${name}" ]] && die "Usage: ./bin/secrets.sh rotate <secret-name>"
  [[ -v "SECRET_DESC[${name}]" ]] || die "Unknown secret: '${name}'"

  echo ""
  info "Rotating secret '${name}'…"

  local is_file="false"
  [[ "${name}" == "sftp_private_key" ]] && is_file="true"

  if [[ "${is_file}" == "true" ]]; then
    read -r -p "  New file path: " val
    [[ -z "${val}" ]] && { warn "Aborted."; return; }
    [[ -f "${val}" ]] || die "File not found: ${val}"
    podman secret rm "${name}" 2>/dev/null || true
    podman secret create "${name}" "${val}"
  else
    read -r -s -p "  New value: " val
    echo ""
    [[ -z "${val}" ]] && { warn "Aborted."; return; }
    podman secret rm "${name}" 2>/dev/null || true
    printf '%s' "${val}" | podman secret create "${name}" -
  fi

  success "Secret '${name}' rotated."
  warn "Restart affected services for the new secret to take effect:"

  case "${name}" in
    tracking_db_password)
      warn "  systemctl --user restart backup-tracking-db.service backup-api.service backup-agent.service" ;;
    internal_api_secret)
      warn "  systemctl --user restart backup-api.service backup-dashboard.service" ;;
    dashboard_session_secret|dashboard_admin_password)
      warn "  systemctl --user restart backup-dashboard.service" ;;
    tracking_db_root_password)
      warn "  systemctl --user restart backup-tracking-db.service" ;;
    mariadb_backup_password|s3_secret_key|sftp_password|sftp_private_key)
      warn "  (takes effect on next backup run)" ;;
  esac
  echo ""
}

cmd_rotate_auto() {
  echo ""
  info "Auto-rotating internal_api_secret and dashboard_session_secret…"
  for name in internal_api_secret dashboard_session_secret; do
    podman secret rm "${name}" 2>/dev/null || true
    NEW="$(openssl rand -hex 32)"
    printf '%s' "${NEW}" | podman secret create "${name}" -
    success "  Rotated '${name}'."
  done
  warn "Restarting api and dashboard services…"
  systemctl --user restart backup-api.service backup-dashboard.service 2>/dev/null \
    && success "Services restarted." \
    || warn "Services not running — changes take effect on next start."
  echo ""
}

cmd_delete() {
  local name="${1:-}"
  [[ -z "${name}" ]] && die "Usage: ./bin/secrets.sh delete <secret-name>"
  read -r -p "Delete secret '${name}'? Type 'yes' to confirm: " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || { warn "Aborted."; return; }
  podman secret rm "${name}" && success "Deleted '${name}'." || warn "Not found."
}

cmd_delete_all() {
  echo ""
  echo -e "${RED}${BOLD}This will delete ALL backup_db_container secrets.${RESET}"
  read -r -p "Type 'yes' to confirm: " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || { warn "Aborted."; return; }
  for name in "${REQUIRED_SECRETS[@]}" "${OPTIONAL_SECRETS[@]}"; do
    podman secret rm "${name}" 2>/dev/null && info "  Deleted '${name}'" || true
  done
  success "All secrets removed."
  echo ""
}

# --- dispatch -----------------------------------------------------------------
CMD="${1:-list}"
shift 2>/dev/null || true

case "${CMD}" in
  list)         cmd_list ;;
  create)       cmd_create ;;
  rotate)       cmd_rotate "${1:-}" ;;
  rotate-auto)  cmd_rotate_auto ;;
  delete)       cmd_delete "${1:-}" ;;
  delete-all)   cmd_delete_all ;;
  -h|--help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) die "Unknown command '${CMD}'. Run ./bin/secrets.sh --help" ;;
esac
