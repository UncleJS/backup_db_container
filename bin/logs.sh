#!/usr/bin/env bash
# =============================================================================
# bin/logs.sh — Tail journald logs for backup pod containers
#
# Usage:
#   ./bin/logs.sh                # tail all backup-* services (interleaved)
#   ./bin/logs.sh pod            # pod service only
#   ./bin/logs.sh db             # tracking-db only
#   ./bin/logs.sh api            # backup-api only
#   ./bin/logs.sh dashboard      # backup-dashboard only
#   ./bin/logs.sh agent          # last backup-agent run
#   ./bin/logs.sh timer          # backup-agent.timer events
#   ./bin/logs.sh -n 100         # last 100 lines of all services
#   ./bin/logs.sh api -f         # follow api logs live (pass -f to journalctl)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
die() { echo -e "${RED}[logs] ERROR:${RESET} $*" >&2; exit 1; }

TARGET="${1:-all}"
shift 2>/dev/null || true   # remaining args are passed through to journalctl

# Map friendly name → systemd unit
declare -A UNIT_MAP=(
  [all]=""
  [pod]="backup-pod.service"
  [db]="backup-tracking-db.service"
  [api]="backup-api.service"
  [dashboard]="backup-dashboard.service"
  [agent]="backup-agent.service"
  [timer]="backup-agent.timer"
)

if [[ ! -v UNIT_MAP[${TARGET}] ]]; then
  die "Unknown target '${TARGET}'. Valid: all pod db api dashboard agent timer"
fi

UNIT="${UNIT_MAP[${TARGET}]}"

echo ""
echo -e "${BOLD}=== Logs: ${TARGET} ===${RESET}  (Ctrl-C to exit)"
echo ""

if [[ -z "${UNIT}" ]]; then
  # All backup services interleaved
  exec journalctl --user \
    -u "backup-pod.service" \
    -u "backup-tracking-db.service" \
    -u "backup-api.service" \
    -u "backup-dashboard.service" \
    -u "backup-agent.service" \
    --no-pager "$@"
else
  exec journalctl --user -u "${UNIT}" --no-pager "$@"
fi
