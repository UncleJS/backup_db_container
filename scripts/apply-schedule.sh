#!/bin/bash
# =============================================================================
# scripts/apply-schedule.sh — Host-side: sync schedule from DB → systemd timer
#
# PURPOSE
#   Reads the current backup schedule from the tracking API, converts the cron
#   expression to a systemd OnCalendar value, rewrites the timer unit file,
#   and reloads systemd so the new schedule takes effect immediately.
#
#   This script MUST be run on the HOST (not inside a container) because it
#   writes to ~/.config/containers/systemd/ and calls `systemctl --user`.
#
# WHEN TO RUN
#   Run this script any time the schedule is changed via the dashboard or API:
#     ./scripts/apply-schedule.sh
#   A --dry-run flag prints what would be written without making any changes.
#
# WHY NOT AUTO-APPLY FROM THE API?
#   The API runs inside a container and does not have access to the host's
#   systemd user session.  The host-side timer unit file is owned by the host
#   user, not the container user.  Therefore, schedule changes require a
#   host-side apply step after saving to the DB.  The dashboard reminds the
#   user with a banner when the schedule is saved.
#
# CRON → SYSTEMD CALENDAR CONVERSION LIMITATIONS
#   This conversion is intentionally simple.  It handles the common 5-field
#   "MIN HOUR DOM MON DOW" format with single values or "*".
#
#   NOT SUPPORTED:
#     • Step values (*/5, 0-6/2)
#     • Ranges (1-5, 8-12)
#     • Lists (1,3,5)
#     • @reboot, @daily and other cron shortcuts
#     • Weekday ranges (Mon-Fri)
#
#   If your schedule requires these features, edit the timer file manually:
#     ~/.config/containers/systemd/backup-agent.timer
#   and run `systemctl --user daemon-reload` to apply.  The next call to
#   apply-schedule.sh will overwrite your manual edits, so keep a copy.
#
# USAGE
#   ./scripts/apply-schedule.sh              # apply from API
#   ./scripts/apply-schedule.sh --dry-run    # preview without writing
#
# ENVIRONMENT VARIABLES
#   API_BASE_URL          — API base URL (default: http://localhost:3001)
#   INTERNAL_API_SECRET   — Bearer token; also loaded from
#                           /run/secrets/internal_api_secret if unset
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
API_BASE="${API_BASE_URL:-http://localhost:3001}"
TIMER_UNIT="backup-agent.timer"

# Quadlet reads timer units from ~/.config/containers/systemd/.
# This is the canonical path for user-mode Quadlet on RHEL/Fedora/Ubuntu.
TIMER_FILE="${HOME}/.config/containers/systemd/${TIMER_UNIT}"

# $1 is the optional --dry-run flag.  All other args are errors.
DRY_RUN="${1:-}"
if [[ -n "${DRY_RUN}" && "${DRY_RUN}" != "--dry-run" ]]; then
  echo "ERROR: Unknown argument '${DRY_RUN}'.  Valid flags: --dry-run" >&2
  exit 1
fi

# ===========================================================================
# Step 1 — Resolve INTERNAL_API_SECRET
#
# The secret is needed to authenticate the GET /schedule API call.
# Resolution order:
#   1. Already in the environment (e.g. CI, sourced .env)
#   2. Podman secret mount at /run/secrets/internal_api_secret
#      (present if this script is somehow run inside a container)
# ===========================================================================
INTERNAL_API_SECRET="${INTERNAL_API_SECRET:-}"

if [[ -z "${INTERNAL_API_SECRET}" ]] && [[ -f /run/secrets/internal_api_secret ]]; then
  INTERNAL_API_SECRET="$(cat /run/secrets/internal_api_secret)"
  echo "Loaded INTERNAL_API_SECRET from /run/secrets/internal_api_secret"
fi

if [[ -z "${INTERNAL_API_SECRET}" ]]; then
  echo "ERROR: INTERNAL_API_SECRET is not set." >&2
  echo "       Export it in your shell, or ensure /run/secrets/internal_api_secret exists." >&2
  exit 1
fi

# ===========================================================================
# Step 2 — Fetch schedule from API
#
# GET /schedule returns a JSON object with at least:
#   { "cron_expression": "0 2 * * *", "enabled": true }
#
# jq -r '.field // "default"':
#   -r       : raw output (no surrounding quotes)
#   // "..." : alternative operator — use the default if field is null/absent
# ===========================================================================
echo "Fetching schedule from ${API_BASE}/schedule …"
SCHEDULE_JSON="$(curl -sf \
  -H "Authorization: Bearer ${INTERNAL_API_SECRET}" \
  "${API_BASE}/schedule")"

CRON_EXPR="$(echo "${SCHEDULE_JSON}" | jq -r '.cron_expression // "0 2 * * *"')"
ENABLED="$(echo "${SCHEDULE_JSON}"   | jq -r '.enabled // "true"')"

echo "  cron_expression : ${CRON_EXPR}"
echo "  enabled         : ${ENABLED}"

# ===========================================================================
# Step 3 — Convert cron expression to systemd OnCalendar format
#
# CRON FORMAT (5 fields):  MIN HOUR DOM MON DOW
#   MIN  — minute     (0-59)
#   HOUR — hour       (0-23)
#   DOM  — day of month (1-31)
#   MON  — month       (1-12)
#   DOW  — day of week (0=Sun, 1=Mon, … 6=Sat, 7=Sun)
#
# SYSTEMD OnCalendar FORMAT:
#   DOW MON-DOM HH:MM:SS
#   Examples:
#     "Mon-Fri *-*-* 08:00:00"  (weekdays at 08:00)
#     "* *-* 02:00:00"          (every day at 02:00)
#     "Sun *-* 03:30:00"        (every Sunday at 03:30)
#
# MAPPING LOGIC:
#   • DOW: numeric cron DOW → abbreviated systemd weekday name.
#           Both 0 and 7 represent Sunday (cron compatibility).
#           If DOW is "*", systemd uses "*" (any day).
#   • DOM: passed through as-is when not "*".
#   • MON: passed through as-is when not "*".
#           systemd uses "-" to separate month from day: *-MON-DOM
#   • HH:MM are zero-padded to 2 digits via printf '%02d'.
#
# KNOWN LIMITATIONS (see header for full list):
#   • Step values (*/5) and ranges (1-5) are NOT supported.
#     systemd OnCalendar has its own range/step syntax that is not the same
#     as cron's — a direct translation is non-trivial and error-prone.
#     For complex schedules, edit the timer file manually.
# ===========================================================================
parse_cron_to_systemd() {
  local cron_str="$1"
  local min hour dom mon dow

  # `read -r` from a here-string splits on whitespace into exactly 5 vars.
  # If the cron expression has fewer or more fields, this will silently
  # assign empty/wrong values — the :? guards in the main script catch this.
  read -r min hour dom mon dow <<< "${cron_str}"

  # Map numeric cron DOW (0-7) to systemd abbreviated day names.
  # Index 0 and 7 both map to "Sun" for cron compatibility.
  local days_map=("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
  local sys_dow="*"
  if [[ "${dow}" != "*" ]]; then
    # Validate that dow is a single digit (not a range/list/step).
    if [[ "${dow}" =~ ^[0-7]$ ]]; then
      sys_dow="${days_map[${dow}]}"
    else
      echo "WARNING: Complex DOW '${dow}' not supported; defaulting to '*' (every day)." >&2
      sys_dow="*"
    fi
  fi

  # DOM and MON: pass single values through; warn on complex expressions.
  local sys_dom="*"
  if [[ "${dom}" != "*" ]]; then
    if [[ "${dom}" =~ ^[0-9]+$ ]]; then
      sys_dom="${dom}"
    else
      echo "WARNING: Complex DOM '${dom}' not supported; defaulting to '*'." >&2
    fi
  fi

  local sys_mon="*"
  if [[ "${mon}" != "*" ]]; then
    if [[ "${mon}" =~ ^[0-9]+$ ]]; then
      sys_mon="${mon}"
    else
      echo "WARNING: Complex MON '${mon}' not supported; defaulting to '*'." >&2
    fi
  fi

  # Zero-pad hour and minute for the time component.
  # systemd accepts unpadded times but padding is conventional and clearer.
  local h m
  h="$(printf '%02d' "${hour}")"
  m="$(printf '%02d' "${min}")"

  # Final OnCalendar value format: "DOW MON-DOM HH:MM:00"
  # When DOW is "*" and MON-DOM are both "*", this becomes "* *-* HH:MM:00"
  # which systemd interprets as "every day at HH:MM:00".
  echo "${sys_dow} ${sys_mon}-${sys_dom} ${h}:${m}:00"
}

SYSTEMD_CALENDAR="$(parse_cron_to_systemd "${CRON_EXPR}")"
echo "  OnCalendar      : ${SYSTEMD_CALENDAR}"

# ===========================================================================
# Step 4 — Write the updated timer unit file
#
# The timer unit is a Quadlet-compatible systemd timer file.
# Key directives:
#   After=backup-pod.service   — do not fire if the pod isn't running
#   OnCalendar=                — the converted schedule
#   RandomizedDelaySec=60      — add up to 60 s of random jitter to prevent
#                                thundering-herd if multiple hosts share the
#                                same schedule
#   Persistent=true            — if the system was off at the scheduled time,
#                                fire immediately when it comes back online
#
# This file is auto-generated; manual edits will be overwritten on the next
# call to apply-schedule.sh.  See the header for alternatives.
# ===========================================================================
NEW_TIMER="$(cat <<EOF
# =============================================================================
# ${TIMER_UNIT}  — auto-generated by apply-schedule.sh
# Last updated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Cron source : ${CRON_EXPR}
# DO NOT EDIT MANUALLY — changes will be overwritten by apply-schedule.sh.
# To customise, edit scripts/apply-schedule.sh or write the timer manually.
# =============================================================================
[Unit]
Description=Backup Agent Schedule Timer
After=backup-pod.service

[Timer]
OnCalendar=${SYSTEMD_CALENDAR}
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
EOF
)"

if [[ "${DRY_RUN}" == "--dry-run" ]]; then
  echo ""
  echo "--- DRY RUN: would write to ${TIMER_FILE} ---"
  echo "${NEW_TIMER}"
  echo "--- (no changes made) ---"
  exit 0
fi

# Write the timer file to the Quadlet directory.
echo "${NEW_TIMER}" > "${TIMER_FILE}"
echo "Wrote ${TIMER_FILE}"

# ===========================================================================
# Step 5 — Reload systemd and enable/disable timer
#
# daemon-reload: instructs systemd to re-read all unit files, including the
#   one we just wrote.  Without this step, systemd would use the cached (old)
#   timer definition.
#
# If enabled=true:
#   `enable --now` both enables the unit (persists across reboots via
#   WantedBy=timers.target symlink) AND starts it immediately.
#
# If enabled=false:
#   `disable --now` removes the WantedBy symlink AND stops the currently
#   running timer.  `|| true` handles the case where the timer was already
#   stopped — disable returns non-zero in that case.
# ===========================================================================
systemctl --user daemon-reload
echo "Reloaded systemd daemon."

if [[ "${ENABLED}" == "true" ]]; then
  systemctl --user enable --now "${TIMER_UNIT}"
  echo "Timer enabled and started."
  echo "Next activation: $(systemctl --user list-timers "${TIMER_UNIT}" --no-pager 2>/dev/null \
    | grep "backup-agent" | awk '{print $1, $2}' || echo "(check with: systemctl --user list-timers)")"
else
  systemctl --user disable --now "${TIMER_UNIT}" || true
  echo "Timer disabled (scheduled backups paused)."
  echo "To re-enable: set enabled=true in the dashboard and re-run this script."
fi

echo "Done."
