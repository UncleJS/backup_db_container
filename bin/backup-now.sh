#!/usr/bin/env bash
# =============================================================================
# bin/backup-now.sh — Trigger an immediate (manual) backup run
#
# PURPOSE
#   Initiates a backup outside the normal scheduled window.  Two mechanisms
#   are tried in order:
#
#     1. API trigger (preferred)
#        POST /trigger with the internal shared secret.  The API writes the
#        sentinel file /tmp/backup-trigger inside the agent container AND
#        creates a backup_run record with trigger_type="manual" in the tracking
#        DB before the agent starts.  This gives the best audit trail.
#
#     2. systemd direct start (fallback)
#        If INTERNAL_API_SECRET is unavailable (e.g. running from a fresh
#        terminal without exporting it), the script falls back to:
#          systemctl --user start backup-agent.service
#        The agent itself will detect /tmp/backup-trigger written by the API
#        on the next run, or will create its own run record with trigger_type
#        inferred from whether the sentinel file exists at startup.
#
# SENTINEL FILE MECHANISM
#   When the API receives POST /trigger it writes /tmp/backup-trigger inside
#   the running backup-agent container (via `podman exec`).  The agent's
#   backup.sh checks for this file at startup:
#     • File exists → TRIGGER_TYPE=manual, file is removed
#     • File absent → TRIGGER_TYPE=scheduled (normal timer activation)
#   This avoids the need to pass command-line arguments to the one-shot service.
#
# SECRET LOADING (three-level cascade)
#   The INTERNAL_API_SECRET is needed to authenticate the POST /trigger call.
#   It is resolved in this priority order:
#     Level 1: Environment variable already exported in the calling shell.
#              Useful in CI/CD pipelines or scripted deployments.
#     Level 2: /run/secrets/internal_api_secret (Podman secret mount).
#              Only available when this script is running INSIDE a container
#              that has the secret mounted (unusual for a host-side bin/ script,
#              but supported for completeness).
#     Level 3: ${HOME}/.config/backup-agent/env (host-side env file).
#              bin/install.sh optionally writes this file so the operator can
#              source it once.  The file must contain:
#                export INTERNAL_API_SECRET=<value>
#   If none of the three levels yields a secret, the script falls back to the
#   direct systemd path (no API call).
#
# USAGE
#   ./bin/backup-now.sh             # trigger and tail logs until Ctrl-C
#   ./bin/backup-now.sh --no-tail   # trigger and return immediately
#
# NOTES
#   • Requires: curl, systemctl (user session); jq recommended for API response
#   • The log tail (default behaviour) follows journald in real time.
#     Press Ctrl-C to stop following — the backup continues in the background.
#   • Exit code 0 means the trigger was accepted; it does NOT mean the backup
#     completed successfully.  Check ./bin/status.sh or the dashboard.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[backup-now]${RESET} $*"; }
success() { echo -e "${GREEN}[backup-now]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[backup-now]${RESET} $*"; }
die()     { echo -e "${RED}[backup-now] ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
NO_TAIL=false   # default: tail the journald logs after triggering

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-tail)
      # Return immediately after the trigger is accepted.
      # Useful in non-interactive scripts where you don't want to block.
      NO_TAIL=true
      shift
      ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown argument: $1  (valid flags: --no-tail)"
      ;;
  esac
done

echo ""
echo -e "${BOLD}=== Manual backup trigger ===${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Secret resolution — three-level cascade (see header for rationale)
# ---------------------------------------------------------------------------
API_BASE="http://localhost:3001"

# Level 1: already in the environment
INTERNAL_API_SECRET="${INTERNAL_API_SECRET:-}"

# Level 2: Podman secret mount (container-side; rarely used from host scripts)
if [[ -z "${INTERNAL_API_SECRET}" ]] && [[ -f /run/secrets/internal_api_secret ]]; then
  INTERNAL_API_SECRET="$(cat /run/secrets/internal_api_secret)"
  info "Loaded INTERNAL_API_SECRET from /run/secrets/internal_api_secret"
fi

# Level 3: host-side env file written by bin/install.sh or manually by operator
if [[ -z "${INTERNAL_API_SECRET}" ]] && [[ -f "${HOME}/.config/backup-agent/env" ]]; then
  # shellcheck source=/dev/null
  # source: reads the file in the current shell so the exported variable
  # becomes available immediately without a subprocess.
  source "${HOME}/.config/backup-agent/env"
  info "Loaded INTERNAL_API_SECRET from ${HOME}/.config/backup-agent/env"
fi

# ---------------------------------------------------------------------------
# Trigger the backup
# ---------------------------------------------------------------------------
if [[ -n "${INTERNAL_API_SECRET}" ]]; then
  # --- Path A: API trigger (preferred) ---
  # POST /trigger authenticates with the internal shared secret (Bearer token),
  # writes the sentinel file into the agent container, creates a run record,
  # then starts backup-agent.service via the systemd D-Bus API.
  info "Triggering via API (POST ${API_BASE}/trigger)…"

  # -o /tmp/…: save response body to a temp file so we can display it after
  # checking the HTTP status code (which is captured separately via -w).
  # -w "%{http_code}": append only the HTTP status code to stdout.
  HTTP_STATUS=$(curl -sf \
    -o /tmp/backup-trigger-response.json \
    -w "%{http_code}" \
    -X POST "${API_BASE}/trigger" \
    -H "Authorization: Bearer ${INTERNAL_API_SECRET}" \
    -H "Content-Type: application/json" \
    2>/dev/null || echo "000")
  # HTTP 000 means curl itself failed (connection refused, DNS failure, etc.)

  if [[ "${HTTP_STATUS}" == "200" || "${HTTP_STATUS}" == "202" ]]; then
    RESPONSE=$(cat /tmp/backup-trigger-response.json 2>/dev/null || echo "{}")
    success "API trigger accepted (HTTP ${HTTP_STATUS}): ${RESPONSE}"
  else
    # API returned an unexpected status (e.g. 401, 503) or curl failed entirely.
    # Fall back to the direct systemd path so the backup still runs.
    warn "API trigger returned HTTP ${HTTP_STATUS} — falling back to direct systemd start."
    systemctl --user start backup-agent.service
  fi

else
  # --- Path B: Direct systemd start (fallback) ---
  # No secret available.  We bypass the API and start the service directly.
  # The backup run will be created by backup.sh itself with trigger_type
  # derived from the absence of the sentinel file (treated as "scheduled").
  warn "INTERNAL_API_SECRET not found — triggering via systemd directly."
  warn "To use the API trigger, export INTERNAL_API_SECRET or create:"
  warn "  ${HOME}/.config/backup-agent/env  with:  export INTERNAL_API_SECRET=<value>"
  info "Starting backup-agent.service via systemctl…"
  systemctl --user start backup-agent.service
fi

success "Backup triggered."
echo ""

# ---------------------------------------------------------------------------
# Optional log tail
# ---------------------------------------------------------------------------
if [[ "${NO_TAIL}" == "true" ]]; then
  info "Backup is running in the background."
  info "Follow progress:  ./bin/logs.sh agent"
  info "Check outcome:    ./bin/status.sh"
  echo ""
  exit 0
fi

# Default: tail the journald output for the backup-agent service.
# -f: follow (real-time updates)
# --no-pager: don't page; let output scroll
# Ctrl-C interrupts the tail but does NOT stop the running backup.
info "Tailing backup-agent logs — press Ctrl-C to stop following (backup continues)…"
echo ""
journalctl --user -u backup-agent.service -f --no-pager
