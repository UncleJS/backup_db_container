#!/usr/bin/env bash
# =============================================================================
# bin/start.sh — Start the backup pod and all associated services
#
# PURPOSE
#   Brings up the entire backup-pod systemd service (which in turn starts all
#   four containers: tracking-db, backup-agent, api, dashboard) and enables
#   the backup-agent.timer so scheduled backups will fire automatically.
#
# USAGE
#   ./bin/start.sh          # start everything and return immediately
#   ./bin/start.sh --wait   # start and poll until tracking-db passes its
#                           # health check (or timeout after 60 s)
#
# STARTUP SEQUENCE (Quadlet-managed)
#   1. systemctl daemon-reload    — makes Quadlet regenerate .service units
#                                   from the .container/.pod files in
#                                   ~/.config/containers/systemd/
#   2. start backup-pod.service   — Podman creates the pod network and starts
#                                   all member containers in dependency order:
#                                     tracking-db → api → dashboard → agent
#   3. start backup-agent.timer   — enables scheduled backups
#
# WHY --wait ONLY POLLS tracking-db
#   The tracking-db (MariaDB) is the innermost dependency.  If it is healthy,
#   the API (which waits for it in its entrypoint) will also be ready, and the
#   dashboard can render its first SSR page.  Polling the API /health endpoint
#   directly would require the secret to be available here on the host, so
#   polling the MariaDB health check via `podman healthcheck run` is simpler
#   and sufficient.
#
# NOTES
#   • Requires: podman, systemctl (user session), Quadlet units installed
#     by bin/install.sh
#   • Does NOT require root.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers — see rebuild.sh for rationale on always-on colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[start]${RESET} $*"; }
success() { echo -e "${GREEN}[start]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[start]${RESET} $*"; }
die()     { echo -e "${RED}[start] ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
WAIT=false   # default: fire-and-forget; do not block waiting for health checks

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      # Block until tracking-db reports healthy (or 60 s timeout).
      # Useful in scripts or CI where subsequent steps need the API to be up.
      WAIT=true
      shift
      ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown argument: $1  (valid flags: --wait)"
      ;;
  esac
done

echo ""
echo -e "${BOLD}=== Starting backup pod ===${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Reload systemd daemon
#
# Quadlet converts .container/.pod files into .service units at daemon-reload
# time.  Without this step, edits to Quadlet files (e.g. after install.sh)
# would not be picked up and the old unit definitions would be used.
# This is always safe to run even if nothing changed.
# ---------------------------------------------------------------------------
info "Reloading systemd daemon (picks up any Quadlet changes)…"
systemctl --user daemon-reload

# ---------------------------------------------------------------------------
# Step 2 — Start the pod service
#
# backup-pod.service is a Quadlet-generated service that manages the pod
# itself.  Starting it automatically starts all containers that declare
# "Pod=backup-pod.pod" in their .container files, because systemd resolves
# the BindsTo= and After= dependencies that Quadlet injects.
# ---------------------------------------------------------------------------
info "Starting backup-pod.service…"
systemctl --user start backup-pod.service
success "Pod started."

# ---------------------------------------------------------------------------
# Step 3 — Start the backup timer
#
# backup-agent.timer is a Quadlet-generated timer that fires the one-shot
# backup-agent.service on the configured schedule (default: daily at 02:00).
# Starting the timer here means scheduled backups resume automatically every
# time the pod is started.  The timer is NOT started by backup-pod.service
# itself — it is a separate unit so it can be paused independently with
# ./bin/stop.sh --timer.
# ---------------------------------------------------------------------------
info "Starting backup-agent.timer…"
systemctl --user start backup-agent.timer
success "Timer started."

# ---------------------------------------------------------------------------
# Optional: wait for tracking-db health check
#
# The MariaDB container declares a HEALTHCHECK in its Containerfile:
#   HEALTHCHECK CMD mariadb-admin ping -h localhost ...
# `podman healthcheck run tracking-db` returns 0 when healthy, non-zero when
# unhealthy or when the container is still initialising.
#
# We poll every 3 seconds with a 60-second hard deadline.  On a typical host
# tracking-db becomes healthy within 10-20 seconds of first start (data dir
# init) or 2-5 seconds on subsequent starts (warm data dir).
# ---------------------------------------------------------------------------
if [[ "${WAIT}" == "true" ]]; then
  echo ""
  info "Waiting for tracking-db to become healthy (up to 60 s)…"

  # Compute absolute deadline timestamp to avoid drift from sleep imprecision.
  DEADLINE=$(( $(date +%s) + 60 ))

  while true; do
    NOW=$(date +%s)
    if [[ "${NOW}" -ge "${DEADLINE}" ]]; then
      warn "Timed out waiting for tracking-db health check."
      warn "Run:  podman healthcheck run tracking-db"
      warn "      ./bin/logs.sh tracking-db"
      break
    fi

    # `podman healthcheck run` executes the HEALTHCHECK CMD from the image.
    # Redirect stderr to /dev/null to suppress "healthy/unhealthy" status lines.
    if podman healthcheck run tracking-db 2>/dev/null; then
      success "tracking-db is healthy."
      break
    fi

    # Not yet healthy — wait before next poll.
    sleep 3
  done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}Pod is running.${RESET}"
echo -e "  Dashboard     :  ${CYAN}http://localhost:3000${RESET}"
echo -e "  API / Swagger :  ${CYAN}http://localhost:3001/swagger${RESET}"
echo -e "  Status        :  ${CYAN}./bin/status.sh${RESET}"
echo -e "  Logs          :  ${CYAN}./bin/logs.sh${RESET}"
echo -e "  Backup now    :  ${CYAN}./bin/backup-now.sh${RESET}"
echo ""
