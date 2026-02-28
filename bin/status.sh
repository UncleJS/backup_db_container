#!/usr/bin/env bash
# =============================================================================
# bin/status.sh — Show runtime status of all backup pod services and containers
#
# PURPOSE
#   Provides a single-screen overview of:
#     1. All relevant systemd units (active/inactive/failed + enabled/disabled)
#     2. The next scheduled backup time (from the timer)
#     3. All Podman containers in backup-pod (state, image, ports)
#     4. Host backup directory (file count + total disk usage)
#     5. Live API health check result (from /health endpoint)
#
# USAGE
#   ./bin/status.sh
#
# OUTPUT COLOUR CODING
#   Green   — unit is active / container is Up
#   Yellow  — unit is inactive / container has exited (non-zero)
#   Red     — unit has failed / container is in unknown state
#
# NOTES
#   • Requires: podman, systemctl (user session), curl
#   • Does NOT require root.
#   • All checks are read-only; this script makes no changes.
#   • Some values may show "(timer not active)" or "unreachable" if the pod
#     is not running — this is expected when the pod is stopped.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colour codes
# DIM is used for secondary information (e.g. enabled/disabled state) to
# visually de-emphasise it relative to the primary active state.
# ---------------------------------------------------------------------------
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# Warn helper used in the podman ps fallback path
warn() { echo -e "${YELLOW}[status]${RESET} $*"; }

# ---------------------------------------------------------------------------
# Lists of units and containers to inspect
#
# SERVICES: the five systemd units that together constitute the backup system.
#   backup-pod.service        — the pod lifecycle unit (Quadlet-generated)
#   backup-tracking-db.service — MariaDB tracking database container
#   backup-api.service         — Elysia API container
#   backup-dashboard.service   — Next.js dashboard container
#   backup-agent.timer         — schedules the one-shot backup-agent.service
#
# CONTAINERS: the four Podman containers inside the pod.
#   Note: backup-agent is one-shot; it will show "Exited 0" between runs,
#   which is expected and shown as Yellow (not Red) based on status prefix.
# ---------------------------------------------------------------------------
SERVICES=(
  backup-pod.service
  backup-tracking-db.service
  backup-api.service
  backup-dashboard.service
  backup-agent.timer
)

CONTAINERS=(
  tracking-db
  backup-api
  backup-dashboard
  backup-agent
)

echo ""
echo -e "${BOLD}=== backup_db_container status ===${RESET}"
echo ""

# ===========================================================================
# Section 1 — Systemd units
# ===========================================================================
echo -e "${BOLD}Systemd units:${RESET}"
printf "  %-40s %s\n" "Unit" "State"
# Print a separator line: 38 dashes for the Unit column, 5 for State
printf "  %-40s %s\n" "$(printf '%0.s-' {1..38})" "-----"

for svc in "${SERVICES[@]}"; do
  # is-active returns the active state as a string: active, inactive, failed,
  # activating, deactivating, etc.  We use `|| echo "inactive"` to handle the
  # case where the unit does not exist (systemctl returns non-zero).
  active=$(systemctl --user is-active "${svc}" 2>/dev/null || echo "inactive")

  # is-enabled returns: enabled, disabled, static, masked, alias, indirect.
  # We only care about enabled vs disabled for display purposes.
  enabled=$(systemctl --user is-enabled "${svc}" 2>/dev/null || echo "disabled")

  # Colour the active state for quick visual scanning.
  case "${active}" in
    active)   colour="${GREEN}"  ;;   # running as expected
    failed)   colour="${RED}"    ;;   # crashed / failed to start
    *)        colour="${YELLOW}" ;;   # inactive, activating, deactivating, etc.
  esac

  # Format: padded unit name | coloured active state | dimmed enabled state
  printf "  %-40s ${colour}%-10s${RESET} (${DIM}%s${RESET})\n" \
    "${svc}" "${active}" "${enabled}"
done

# ===========================================================================
# Section 2 — Next scheduled backup
# ===========================================================================
echo ""
echo -e "${BOLD}Next scheduled backup:${RESET}"

# `systemctl list-timers` outputs a table; we grep for the timer name and
# extract columns 1 and 2 (next activation date and time).
# If the timer is not active, this produces no output — we fall back to the
# "(timer not active)" placeholder via the default expansion.
next=$(systemctl --user list-timers backup-agent.timer --no-pager 2>/dev/null \
  | grep "backup-agent" | awk '{print $1, $2}' || echo "")
echo "  ${next:-  (timer not active)}"

# ===========================================================================
# Section 3 — Podman containers
# ===========================================================================
echo ""
echo -e "${BOLD}Podman containers:${RESET}"
printf "  %-25s %-12s %-20s %s\n" "Name" "Status" "Image" "Ports"
printf "  %-25s %-12s %-20s %s\n" \
  "$(printf '%0.s-' {1..23})" \
  "$(printf '%0.s-' {1..10})" \
  "$(printf '%0.s-' {1..18})" \
  "-----"

# podman ps --all: include stopped/exited containers so we see the full picture.
# --filter "pod=backup-pod": only containers in our pod (not unrelated containers).
# --format "table ...": tab-separated fields so we can IFS-split cleanly.
# tail -n +2: skip the header row that podman emits for the "table" format.
#
# The `while IFS=$'\t' read` loop processes each container row:
#   name   — container name (e.g. "backup-api")
#   status — full status string (e.g. "Up 3 hours", "Exited (0) 2 minutes ago")
#   image  — full image reference (e.g. "localhost/backup-api:latest")
#   ports  — port mapping string (e.g. "0.0.0.0:3001->3001/tcp")
#
# Colour logic:
#   "Up*"     — container is running (Green)
#   "Exited*" — container has stopped; could be normal (one-shot) or error (Yellow)
#   other     — unknown / paused / created (Red)
#
# ${status%% *} — strips everything from the first space onward, leaving just
#   the first word ("Up", "Exited", "Created", etc.) for the compact display.
#   e.g. "Up 3 hours" → "Up"
#
# ${image##*/} — strips everything up to and including the last "/" so only
#   the image name:tag is shown without the registry/namespace prefix.
#   e.g. "localhost/backup-api:latest" → "backup-api:latest"
podman ps --all --filter "pod=backup-pod" \
  --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}" 2>/dev/null \
  | tail -n +2 \
  | while IFS=$'\t' read -r name status image ports; do
      case "${status}" in
        Up*)      colour="${GREEN}"  ;;  # container is running
        Exited*)  colour="${YELLOW}" ;;  # stopped; may be normal (one-shot agent)
        *)        colour="${RED}"    ;;  # unknown state
      esac
      printf "  %-25s ${colour}%-12s${RESET} %-20s %s\n" \
        "${name}" \
        "${status%% *}" \
        "${image##*/}" \
        "${ports}"
    done || warn "  (no containers found in backup-pod — is the pod running?)"

# ===========================================================================
# Section 4 — Host backup directory
# ===========================================================================
echo ""
echo -e "${BOLD}Host backup directory:${RESET}"

# This is the bind-mount host path set by install.sh.
# The container sees it as /backups; on the host it lives under XDG data dir.
BACKUP_DIR="${HOME}/.local/share/backup-agent/backups"

if [[ -d "${BACKUP_DIR}" ]]; then
  # Count all regular files recursively — excludes directories and symlinks.
  count=$(find "${BACKUP_DIR}" -type f 2>/dev/null | wc -l)
  # du -sh: human-readable size of the entire directory tree.
  size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | awk '{print $1}')
  echo "  ${BACKUP_DIR}"
  echo "  Files: ${count}   Size: ${size}"
else
  # Directory doesn't exist yet — first run hasn't created any backups,
  # or the path was manually removed.  Not an error.
  echo -e "  ${BACKUP_DIR}  ${YELLOW}(not found — no backups yet?)${RESET}"
fi

# ===========================================================================
# Section 5 — API health check
# ===========================================================================
echo ""
echo -e "${BOLD}API health check:${RESET}"

# Call the /health endpoint.  This is the only unauthenticated endpoint on
# the API.  It returns a JSON object with DB connectivity and disk status.
# -sf: silent (no progress) + fail on HTTP error codes.
# Fallback JSON is emitted if curl fails (connection refused, timeout, etc.)
health=$(curl -sf http://localhost:3001/health 2>/dev/null \
  || echo '{"status":"unreachable","error":"API not responding"}')
echo "  ${health}"

echo ""
