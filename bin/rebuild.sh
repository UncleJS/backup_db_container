#!/usr/bin/env bash
# =============================================================================
# bin/rebuild.sh — Rebuild container image(s) and restart affected services
#
# PURPOSE
#   After editing source code, Containerfiles, or config, run this script to
#   rebuild the affected image(s) and (where applicable) restart the running
#   systemd service so the new image is picked up immediately.
#
# USAGE
#   ./bin/rebuild.sh                    # rebuild ALL four images in dependency order
#   ./bin/rebuild.sh agent              # rebuild the backup-agent image only
#   ./bin/rebuild.sh api                # rebuild the Elysia API image only
#   ./bin/rebuild.sh dashboard          # rebuild the Next.js dashboard image only
#   ./bin/rebuild.sh tracking-db        # rebuild the MariaDB tracking-db image only
#   ./bin/rebuild.sh api dashboard      # rebuild multiple named targets
#   ./bin/rebuild.sh --no-cache         # rebuild all without using the layer cache
#   ./bin/rebuild.sh --no-cache agent   # rebuild one target without layer cache
#
# DEPENDENCY ORDER (when rebuilding all)
#   agent → tracking-db → api → dashboard
#   The agent image is the foundation that embeds the backup scripts.
#   tracking-db must exist before api can migrate the schema.
#   api must be up before dashboard can perform SSR API calls.
#   Rebuilding all in this order avoids broken intermediate states.
#
# RESTART BEHAVIOUR
#   • backup-agent — one-shot service (not persistent); no restart needed.
#     The next scheduled or manual run will automatically use the new image.
#   • tracking-db, api, dashboard — long-running services; systemctl restart
#     is issued if the service is currently active.  If the service is not
#     active (e.g. the pod is stopped) the restart is silently skipped so
#     the operator can start everything with bin/start.sh at their convenience.
#
# NOTES
#   • Requires: podman, systemctl (user session)
#   • Does NOT require root — all images are built in the rootless Podman store.
#   • Build context for each image is the subdirectory containing its sources.
# =============================================================================
set -euo pipefail

# Resolve the repository root regardless of CWD when this script is invoked.
# dirname + ".." lets us call the script from anywhere (e.g. CI scripts, cron).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Terminal colour codes — only used in interactive output, not in log files.
# We intentionally check no $TERM so colours are always emitted; redirect to
# a file if you want plain output.
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[rebuild]${RESET} $*"; }
success() { echo -e "${GREEN}[rebuild]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[rebuild]${RESET} $*"; }
die()     { echo -e "${RED}[rebuild] ERROR:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
NO_CACHE=""   # empty string means "use cache" (no flag passed to podman build)
TARGETS=()    # list of targets requested; empty = rebuild all

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache)
      # Pass --no-cache to every podman build invocation so every layer is
      # re-fetched from the registry and re-executed.  Useful when a base
      # image (e.g. mariadb:lts, oven/bun:1-alpine) has been updated upstream.
      NO_CACHE="--no-cache"
      shift
      ;;
    -h|--help)
      # Print the usage block from the top of this file (lines 2-12), stripping
      # the leading "# " prefix so it reads as plain text.
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    agent|api|dashboard|tracking-db)
      # Accumulate valid target names into the TARGETS array.
      TARGETS+=("$1")
      shift
      ;;
    *)
      die "Unknown argument: $1  (valid targets: agent api dashboard tracking-db)"
      ;;
  esac
done

# If no explicit targets were given, rebuild all four in dependency order.
# Order matters: agent base → tracking-db → api → dashboard.
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(agent tracking-db api dashboard)

# ---------------------------------------------------------------------------
# restart_service()
#   Restart a systemd user service if it is currently active.
#   Silently skips if the service is stopped or does not exist, so that
#   calling this script while the pod is down does not fail noisily.
#
#   Parameters:
#     $1  svc  — systemd service name (e.g. "backup-api.service")
# ---------------------------------------------------------------------------
restart_service() {
  local svc="$1"
  if systemctl --user is-active --quiet "${svc}" 2>/dev/null; then
    info "  Restarting ${svc}…"
    # --user: operate on the calling user's systemd instance (no sudo needed)
    systemctl --user restart "${svc}"
    success "  ${svc} restarted."
  else
    # Service is not active — perhaps the whole pod is stopped.
    # This is not an error: the operator can start the pod later with bin/start.sh.
    warn "  ${svc} is not running — skipping restart (start with: ./bin/start.sh)."
  fi
}

# ---------------------------------------------------------------------------
# Main build loop
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}=== Rebuild ===${RESET}"
[[ -n "${NO_CACHE}" ]] && warn "Building with --no-cache (all layers will be re-fetched)"
echo ""

# Step counter: dynamically numbered so partial rebuilds show accurate X/Y.
STEP=0
TOTAL="${#TARGETS[@]}"

for target in "${TARGETS[@]}"; do
  (( STEP++ )) || true   # || true prevents set -e from aborting on arithmetic 0

  case "${target}" in

    # -------------------------------------------------------------------------
    # backup-agent
    #   Base image : mariadb:lts  (includes mariadb-backup + mariadb-dump)
    #   Context    : repo root (scripts/ must be inside the build context)
    #   Restart    : N/A — agent is a one-shot service triggered by the timer
    # -------------------------------------------------------------------------
    agent)
      info "[${STEP}/${TOTAL}] Building backup-agent…"
      podman build ${NO_CACHE} \
        -f "${REPO_DIR}/Containerfile.agent" \
        -t localhost/backup-agent:latest \
        "${REPO_DIR}"   # build context = repo root so COPY scripts/ works
      success "backup-agent built."
      # The agent is a one-shot systemd service (Type=oneshot).  It is started
      # by the timer or manually with backup-now.sh.  There is no persistent
      # process to restart; the next activation picks up the new image.
      warn "  backup-agent is one-shot — next run will use the new image automatically."
      ;;

    # -------------------------------------------------------------------------
    # backup-tracking-db
    #   Base image : mariadb:lts (custom init SQL baked in via Containerfile)
    #   Context    : tracking-db/
    #   Restart    : yes — persistent container holding the tracking database
    #
    #   NOTE: restarting tracking-db causes a brief API outage because the API
    #   container will lose its DB connection.  The API auto-reconnects via the
    #   mysql2 connection pool, so recovery is automatic within a few seconds.
    # -------------------------------------------------------------------------
    tracking-db)
      info "[${STEP}/${TOTAL}] Building backup-tracking-db…"
      podman build ${NO_CACHE} \
        -f "${REPO_DIR}/tracking-db/Containerfile.tracking-db" \
        -t localhost/backup-tracking-db:latest \
        "${REPO_DIR}/tracking-db"   # context limited to tracking-db/ for smaller image
      success "backup-tracking-db built."
      restart_service "backup-tracking-db.service"
      ;;

    # -------------------------------------------------------------------------
    # backup-api
    #   Base image : oven/bun:1-alpine
    #   Context    : api/
    #   Restart    : yes — persistent Elysia HTTP server on port 3001
    # -------------------------------------------------------------------------
    api)
      info "[${STEP}/${TOTAL}] Building backup-api…"
      podman build ${NO_CACHE} \
        -f "${REPO_DIR}/api/Containerfile.api" \
        -t localhost/backup-api:latest \
        "${REPO_DIR}/api"
      success "backup-api built."
      restart_service "backup-api.service"
      ;;

    # -------------------------------------------------------------------------
    # backup-dashboard
    #   Base image : node:20-alpine (multi-stage; output: standalone baked in)
    #   Context    : dashboard/
    #   Restart    : yes — persistent Next.js server on port 3000
    #
    #   NOTE: The Containerfile uses Next.js `output: "standalone"` so only the
    #   minimal set of files is included in the final image stage.  This is set
    #   in next.config.ts.  Without it the image would be 10x larger.
    # -------------------------------------------------------------------------
    dashboard)
      info "[${STEP}/${TOTAL}] Building backup-dashboard…"
      podman build ${NO_CACHE} \
        -f "${REPO_DIR}/dashboard/Containerfile.dashboard" \
        -t localhost/backup-dashboard:latest \
        "${REPO_DIR}/dashboard"
      success "backup-dashboard built."
      restart_service "backup-dashboard.service"
      ;;

  esac
  echo ""
done

success "Rebuild complete (${TOTAL} target(s))."
echo ""
