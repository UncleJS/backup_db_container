#!/usr/bin/env bash
# =============================================================================
# scripts/upload_sftp.sh — Upload a backup run directory via SFTP using rclone
#
# PURPOSE
#   Transfers all files from a completed backup run directory to a remote SFTP
#   server using rclone's SFTP backend, then records per-file upload_attempts
#   rows in the tracking DB (mirrors upload_s3.sh behaviour).
#
# AUTHENTICATION — two modes, auto-detected
#   KEY mode  (preferred):  SSH private key, PEM content from Podman secret
#   PASSWORD mode:          Password via rclone's obscured password format
#
#   AUTO-DETECTION LOGIC
#     The SFTP_AUTH_TYPE env var defaults to "auto".  In auto mode:
#       • If /run/secrets/sftp_private_key exists AND is non-empty → KEY mode
#       • Otherwise → PASSWORD mode
#     You can override with SFTP_AUTH_TYPE=key or SFTP_AUTH_TYPE=password.
#
#   WHY rclone obscure FOR PASSWORDS?
#     rclone's SFTP backend requires passwords in its own obfuscated format,
#     not plaintext.  `rclone obscure <plaintext>` encodes the password into
#     the expected format at runtime so we never store an obscured credential
#     in a file — it is generated on the fly from the Podman secret.
#     IMPORTANT: rclone obscure is NOT encryption; it is reversible encoding.
#     The security comes from the Podman secret mechanism, not from obscure.
#
#   WHY KEY_PEM INSTEAD OF A KEY FILE?
#     rclone's SFTP backend supports embedding the PEM content directly via
#     the RCLONE_CONFIG_<REMOTE>_KEY_PEM environment variable.  This avoids
#     writing the private key to disk (even to /tmp), which is the correct
#     approach in a container environment where the filesystem may be logged
#     or inspected.  The Podman secret is read once via `cat` and passed as
#     an env var that exists only in the process's memory.
#
# SET_MODTIME=false — WHY?
#   rclone by default tries to set the modification time on remote files after
#   uploading them.  Many SFTP servers (especially on NAS devices or restricted
#   hosting) return an error when the client tries to set mtime via the
#   setstat/utimes SFTP request.  Setting SET_MODTIME=false prevents these
#   spurious errors.  The tradeoff is that rclone cannot use mtime for
#   skip-on-same-mtime comparisons, but since we're always uploading new files
#   (each run to a new timestamped directory), this is irrelevant.
#
# REMOTE PATH STRUCTURE
#   sftp://<SFTP_HOST>/<SFTP_REMOTE_PATH>/<RUN_TS>/
#   Example: sftp://backup.example.com/backups/20260201-020000/
#
# ARGUMENTS (positional)
#   $1  run_dir         — absolute path to the current run's working directory
#   $2  run_ts          — timestamp string (e.g. "20260201-020000")
#   $3  api_url         — base URL of the tracking API
#   $4  run_id          — integer run ID
#   $5  api_secret      — INTERNAL_API_SECRET for API auth
#
# ENVIRONMENT VARIABLES
#   SFTP_HOST           — SFTP server hostname or IP (required)
#   SFTP_PORT           — SFTP port (default: 22)
#   SFTP_USER           — SFTP username (required)
#   SFTP_REMOTE_PATH    — base path on the remote (default: /backups)
#   SFTP_AUTH_TYPE      — "auto" | "key" | "password" (default: auto)
#   SFTP_PASSWORD       — plaintext password; loaded from Podman secret by
#                         backup.sh before this script is called
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Positional arguments
# ---------------------------------------------------------------------------
RUN_DIR="$1"
RUN_TS="$2"
API_BASE_URL="$3"
RUN_ID="$4"
INTERNAL_API_SECRET="$5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/db_record.sh"

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [sftp] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [sftp][ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# Validate and default environment variables
# ---------------------------------------------------------------------------
SFTP_HOST="${SFTP_HOST:?SFTP_HOST must be set in backup.env}"
SFTP_PORT="${SFTP_PORT:-22}"
SFTP_USER="${SFTP_USER:?SFTP_USER must be set in backup.env}"
SFTP_REMOTE_PATH="${SFTP_REMOTE_PATH:-/backups}"

# Build the full remote destination path: strip trailing slash from base path,
# then append the run timestamp subdirectory.
REMOTE_DEST="${SFTP_REMOTE_PATH%/}/${RUN_TS}/"

# ---------------------------------------------------------------------------
# Resolve SFTP destination ID from the API (same pattern as upload_s3.sh)
# ---------------------------------------------------------------------------
DEST_ID="$(curl -sf \
  -H "Authorization: Bearer ${INTERNAL_API_SECRET}" \
  "${API_BASE_URL}/destinations?type=sftp&enabled=true" 2>/dev/null \
  | jq -r '.[0].id // 0')"

log "Resolved SFTP destination ID: ${DEST_ID}"

# ---------------------------------------------------------------------------
# Configure rclone SFTP remote via environment variables
#
# Remote name: SFTPTOOL (uppercase, no hyphens — rclone env var naming rule)
# All settings correspond to fields in an rclone SFTP remote configuration.
#
# SHELL_TYPE=unix: tells rclone what shell commands are available on the
#   remote for operations like mkdir.  Always unix for standard Linux/BSD.
#   Without this, rclone may issue commands the remote SFTP server doesn't
#   understand.
#
# SET_MODTIME=false: see header for detailed rationale.
# ---------------------------------------------------------------------------
export RCLONE_CONFIG_SFTPTOOL_TYPE=sftp
export RCLONE_CONFIG_SFTPTOOL_HOST="${SFTP_HOST}"
export RCLONE_CONFIG_SFTPTOOL_USER="${SFTP_USER}"
export RCLONE_CONFIG_SFTPTOOL_PORT="${SFTP_PORT}"
export RCLONE_CONFIG_SFTPTOOL_SHELL_TYPE=unix
export RCLONE_CONFIG_SFTPTOOL_SET_MODTIME=false

# ---------------------------------------------------------------------------
# Authentication mode detection
#
# Three explicit states: auto, key, password
#   auto     — inspect /run/secrets/sftp_private_key; choose key if non-empty
#   key      — always use SSH key regardless of secret file
#   password — always use password; error if SFTP_PASSWORD is empty
# ---------------------------------------------------------------------------
KEY_SECRET_PATH="/run/secrets/sftp_private_key"
SFTP_AUTH_TYPE="${SFTP_AUTH_TYPE:-auto}"

if [[ "${SFTP_AUTH_TYPE}" == "auto" ]]; then
  # -f: file exists; -s: file is non-empty (size > 0)
  if [[ -f "${KEY_SECRET_PATH}" ]] && [[ -s "${KEY_SECRET_PATH}" ]]; then
    SFTP_AUTH_TYPE="key"
    log "Auto-detected auth type: SSH key (secret file present and non-empty)."
  else
    SFTP_AUTH_TYPE="password"
    log "Auto-detected auth type: password (key secret absent or empty)."
  fi
fi

if [[ "${SFTP_AUTH_TYPE}" == "key" ]]; then
  log "Configuring SSH key authentication."

  # Read the entire PEM file content and assign to KEY_PEM env var.
  # rclone accepts the raw PEM content (including newlines) as the value.
  # This means the private key never touches the container filesystem beyond
  # /run/secrets/ (which is a tmpfs mount).
  export RCLONE_CONFIG_SFTPTOOL_KEY_PEM="$(cat "${KEY_SECRET_PATH}")"

elif [[ "${SFTP_AUTH_TYPE}" == "password" ]]; then
  log "Configuring password authentication."

  if [[ -z "${SFTP_PASSWORD:-}" ]]; then
    err "SFTP_AUTH_TYPE=password but SFTP_PASSWORD is empty."
    err "Ensure the sftp_password Podman secret is configured and non-empty."
    exit 1
  fi

  # rclone's SFTP backend requires passwords in an obfuscated (not encrypted)
  # format.  `rclone obscure` encodes a plaintext password to that format.
  # This must be done at runtime (not stored as a pre-obscured value) because:
  #   1. The Podman secret stores the plaintext value.
  #   2. Obscured values are deterministic but tied to a specific rclone build,
  #      so pre-obscuring would be fragile across rclone version upgrades.
  export RCLONE_CONFIG_SFTPTOOL_PASS="$(rclone obscure "${SFTP_PASSWORD}")"

else
  err "Unknown SFTP_AUTH_TYPE: '${SFTP_AUTH_TYPE}'. Must be 'auto', 'key', or 'password'."
  exit 1
fi

# Capture start time before the rclone call for accurate duration tracking.
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log "Uploading ${RUN_DIR} → sftp://${SFTP_HOST}${REMOTE_DEST}"

UPLOAD_STATUS="failed"
UPLOAD_ERROR=""
BYTES_TRANSFERRED=0

# ---------------------------------------------------------------------------
# Execute rclone copy
#
# sftptool:<path>: the rclone remote name followed by the destination path.
# rclone will create intermediate directories on the SFTP server if needed.
#
# --progress, --stats-one-line, --transfers=4: same as upload_s3.sh.
# All output is prefixed with [sftp][rclone] for consistent journald logging.
# ---------------------------------------------------------------------------
if rclone copy "${RUN_DIR}" "sftptool:${REMOTE_DEST}" \
     --progress \
     --stats-one-line \
     --transfers=4 \
     2>&1 | while IFS= read -r line; do log "[rclone] ${line}"; done; then

  log "SFTP upload succeeded."
  UPLOAD_STATUS="success"
  BYTES_TRANSFERRED="$(du -sb "${RUN_DIR}" 2>/dev/null | awk '{print $1}' || echo 0)"

else
  err "rclone SFTP upload failed (exit code: $?)."
  UPLOAD_STATUS="failed"
  UPLOAD_ERROR="rclone exited non-zero"
fi

# ---------------------------------------------------------------------------
# Per-file upload tracking (identical pattern to upload_s3.sh)
# See upload_s3.sh for detailed commentary on this block.
# ---------------------------------------------------------------------------
if [[ "${DEST_ID}" != "0" ]]; then
  log "Recording per-file upload attempts for destination ID=${DEST_ID}…"

  while IFS= read -r filepath; do
    FILE_ID="$(curl -sf \
      -H "Authorization: Bearer ${INTERNAL_API_SECRET}" \
      "${API_BASE_URL}/files?run_id=${RUN_ID}&file_name=$(basename "${filepath}")" 2>/dev/null \
      | jq -r '.[0].id // 0')"

    if [[ "${FILE_ID}" != "0" ]]; then
      FILE_SIZE="$(stat -c%s "${filepath}" 2>/dev/null || echo 0)"
      db_record_upload \
        "${FILE_ID}" \
        "${DEST_ID}" \
        "${UPLOAD_STATUS}" \
        "${FILE_SIZE}" \
        "${UPLOAD_ERROR}" \
        "${STARTED_AT}"
    else
      log "  Skipping upload record for $(basename "${filepath}") — file ID not found."
    fi
  done < <(find "${RUN_DIR}" -maxdepth 1 -type f)
else
  log "No SFTP destination found in tracking DB — skipping per-file upload records."
fi

# Exit non-zero if upload failed, so backup.sh can mark the run as "partial".
[[ "${UPLOAD_STATUS}" == "success" ]]
