#!/usr/bin/env bash
# =============================================================================
# bin/stop.sh — Gracefully stop the backup pod
#
# PURPOSE
#   Stops the running pod (and all containers within it).  By default the
#   backup-agent.timer is LEFT RUNNING so that scheduled backups continue to
#   fire once the pod is restarted.  Pass --timer to also stop the timer if
#   you need to pause all backup activity (e.g. maintenance window).
#
# USAGE
#   ./bin/stop.sh            # stop the pod; timer keeps its schedule
#   ./bin/stop.sh --timer    # stop the pod AND the timer (pauses scheduling)
#
# WHY THE TIMER IS NOT STOPPED BY DEFAULT
#   The timer and the pod are intentionally decoupled.  The timer fires the
#   backup-agent.service (a one-shot job); the pod hosts the long-running
#   services (tracking-db, api, dashboard).  Temporarily stopping the pod
#   for maintenance (e.g. a DB upgrade, image rebuild) should not silently
#   cancel the next scheduled backup.  When the pod restarts, the timer is
#   still active and the next activation will work normally.
#
#   Use --timer only when you want to explicitly disable all backup scheduling
#   (e.g. migrating to a new host, decommissioning the instance).
#
# GRACEFUL SHUTDOWN
#   systemctl stop sends SIGTERM to the container init process.  All images
#   use the default STOPSIGNAL so MariaDB, Bun, and Node all perform clean
#   shutdown (flush buffers, close connections).  The default stop timeout
#   is 90 s; containers that haven't exited by then receive SIGKILL.
#
# NOTES
#   • Requires: podman, systemctl (user session)
#   • Does NOT require root.
#   • `2>/dev/null || warn` pattern: if the service is already stopped,
#     systemctl returns non-zero; we treat that as a non-fatal condition.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[stop]${RESET} $*"; }
success() { echo -e "${GREEN}[stop]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[stop]${RESET} $*"; }
die()     { echo -e "${RED}[stop] ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
STOP_TIMER=false   # default: leave the timer running

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timer)
      # Also stop the backup-agent.timer so no further scheduled runs fire.
      # The timer can be re-enabled with:  systemctl --user start backup-agent.timer
      # or by running:  ./bin/start.sh
      STOP_TIMER=true
      shift
      ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown argument: $1  (valid flags: --timer)"
      ;;
  esac
done

echo ""
echo -e "${BOLD}=== Stopping backup pod ===${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Step 1 (optional) — Stop the timer
#
# Only executed when --timer flag is passed.  Stopping the timer does NOT
# cancel any backup run that is currently in progress (that is a separate
# one-shot service instance); it only prevents future activations.
# ---------------------------------------------------------------------------
if [[ "${STOP_TIMER}" == "true" ]]; then
  info "Stopping backup-agent.timer…"
  # The `|| warn` pattern: if the timer is already stopped, systemctl returns
  # a non-zero exit code; we catch it and emit a warning instead of aborting.
  systemctl --user stop backup-agent.timer 2>/dev/null \
    && success "Timer stopped." \
    || warn "Timer was not running — nothing to stop."
fi

# ---------------------------------------------------------------------------
# Step 2 — Stop the pod service
#
# Stopping backup-pod.service stops all containers in the pod in reverse
# dependency order (dashboard → api → tracking-db), giving each container
# a graceful shutdown window.
#
# Individual container services (backup-tracking-db.service, etc.) do NOT
# need to be stopped separately — they are managed as sub-units of the pod
# and will be stopped as a side-effect.
# ---------------------------------------------------------------------------
info "Stopping backup-pod.service (stops all containers in the pod)…"
systemctl --user stop backup-pod.service 2>/dev/null \
  && success "Pod stopped." \
  || warn "Pod was not running — nothing to stop."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
success "Done."
if [[ "${STOP_TIMER}" == "true" ]]; then
  echo -e "  Timer is stopped. Re-enable scheduling with:  ${CYAN}./bin/start.sh${RESET}"
else
  echo -e "  Timer is still active — scheduled backups will fire when pod is restarted."
fi
echo -e "  Restart the pod with:  ${CYAN}./bin/start.sh${RESET}"
echo ""
