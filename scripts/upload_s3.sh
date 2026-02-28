#!/usr/bin/env bash
# =============================================================================
# scripts/upload_s3.sh — Upload a backup run directory to S3-compatible storage
#
# PURPOSE
#   Uploads all files from a completed backup run directory to an S3-compatible
#   object store using rclone, then records one upload_attempts row per file
#   in the tracking DB.
#
# S3 COMPATIBILITY
#   Uses rclone with PROVIDER=Other (not AWS) to support any S3-compatible
#   endpoint:  MinIO, Wasabi, Backblaze B2 (S3-compatible mode), Cloudflare R2,
#   DigitalOcean Spaces, and standard AWS S3.
#
#   WHY PROVIDER=Other AND NOT PROVIDER=AWS?
#     PROVIDER=AWS enables AWS-specific features like virtual-hosted-style
#     addressing and SigV4 chunked transfer encoding that break with non-AWS
#     endpoints.  PROVIDER=Other uses path-style requests and plain SigV4,
#     which is universally supported.  If you are using real AWS S3, change
#     PROVIDER to "AWS" in the export block — it will still work, and you gain
#     access to AWS-specific optimisations (multipart thresholds, etc.).
#
# RCLONE CONFIGURATION METHOD
#   rclone is configured entirely via environment variables — no rclone.conf
#   file is written to disk.  The naming convention is:
#     RCLONE_CONFIG_<REMOTENAME>_<KEY>=<value>
#   Remote name used here: S3BACKUPTOOL (uppercase, no hyphens).
#   This avoids any risk of credentials leaking into a file on disk.
#
# REMOTE PATH STRUCTURE
#   s3://<S3_BUCKET>/<S3_PATH_PREFIX>/<RUN_TS>/
#   Example: s3://my-bucket/backups/20260201-020000/
#   Each backup run gets its own timestamped subdirectory so runs never
#   overwrite each other and retention scripts can delete whole run dirs.
#
# UPLOAD TRACKING
#   After the rclone transfer finishes (success or failure), this script
#   queries the API for each file's ID (file was registered by backup_mariadb.sh
#   et al.) and creates an upload_attempts record.  If the destination ID
#   cannot be resolved (DEST_ID=0), upload tracking is skipped but the
#   rclone transfer still proceeds — tracking is non-critical.
#
# ARGUMENTS (positional)
#   $1  run_dir         — absolute path to the current run's working directory
#   $2  run_ts          — timestamp string used as the remote subdirectory name
#                         (e.g. "20260201-020000")
#   $3  api_url         — base URL of the tracking API
#   $4  run_id          — integer run ID
#   $5  api_secret      — INTERNAL_API_SECRET for API auth
#
# ENVIRONMENT VARIABLES
#   S3_ENDPOINT         — full HTTPS URL of the S3 endpoint
#                         (default: https://s3.amazonaws.com)
#   S3_BUCKET           — bucket name (required)
#   S3_ACCESS_KEY       — S3 access key ID (required)
#   S3_SECRET_KEY       — S3 secret access key; loaded from Podman secret by
#                         backup.sh before this script is called (required)
#   S3_REGION           — AWS/S3-compatible region (default: us-east-1)
#   S3_PATH_PREFIX      — path prefix inside the bucket (default: "backups/")
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

log()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [s3] $*"; }
err()  { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [s3][ERROR] $*" >&2; }

# ---------------------------------------------------------------------------
# Validate and default environment variables
# ---------------------------------------------------------------------------
S3_ENDPOINT="${S3_ENDPOINT:-https://s3.amazonaws.com}"

# :? syntax: abort with an error message if the variable is unset or empty.
# These are truly required — rclone cannot proceed without them.
S3_BUCKET="${S3_BUCKET:?S3_BUCKET must be set in backup.env}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:?S3_ACCESS_KEY must be set in backup.env}"
S3_SECRET_KEY="${S3_SECRET_KEY:?S3_SECRET_KEY must be set (loaded from Podman secret)}"
S3_REGION="${S3_REGION:-us-east-1}"

# S3_PATH_PREFIX is the "folder" prefix inside the bucket.
# We strip a trailing slash (${..%/}) and then re-add it when constructing
# REMOTE_DEST to guarantee exactly one slash separator.
S3_PATH_PREFIX="${S3_PATH_PREFIX:-backups/}"

# ---------------------------------------------------------------------------
# Resolve destination ID from the API
#
# The destinations table stores S3/SFTP destination configs with an integer
# primary key.  We need this ID to link upload_attempts rows to the correct
# destination.  We query for the first enabled S3 destination.
#
# If the API is unreachable or no S3 destination is configured, DEST_ID=0
# (a sentinel value meaning "unknown").  We still proceed with the upload;
# we just skip tracking.
# ---------------------------------------------------------------------------
DEST_ID="$(curl -sf \
  -H "Authorization: Bearer ${INTERNAL_API_SECRET}" \
  "${API_BASE_URL}/destinations?type=s3&enabled=true" 2>/dev/null \
  | jq -r '.[0].id // 0')"

log "Resolved S3 destination ID: ${DEST_ID}"

# ---------------------------------------------------------------------------
# Construct the remote path
#
# REMOTE_PATH is the rclone remote name (must match the RCLONE_CONFIG_... prefix).
# REMOTE_DEST is the path INSIDE the bucket: <prefix>/<run_timestamp>/
# Full rclone destination: S3BACKUPTOOL:<bucket>/<prefix>/<run_ts>/
# ---------------------------------------------------------------------------
REMOTE_PATH="s3backuptool"   # must be uppercase/alphanumeric to match env var naming
REMOTE_DEST="${S3_PATH_PREFIX%/}/${RUN_TS}/"

# ---------------------------------------------------------------------------
# Configure rclone via environment variables (no config file)
#
# All RCLONE_CONFIG_<REMOTE>_<KEY> variables are set here.  rclone reads them
# at runtime and builds an in-memory remote config — nothing is written to disk.
#
# Key settings explained:
#   TYPE=s3               — use the S3-compatible backend
#   PROVIDER=Other        — generic S3 (not AWS-specific); see header for rationale
#   ACCESS_KEY_ID         — the access key credential
#   SECRET_ACCESS_KEY     — the secret key credential (read from Podman secret)
#   REGION                — AWS region or empty for non-AWS endpoints
#   ENDPOINT              — full URL; rclone sends all requests here
#   NO_CHECK_BUCKET=false — verify the bucket exists before uploading;
#                           set to true to skip the HEAD bucket check if the
#                           IAM policy doesn't allow s3:HeadBucket
# ---------------------------------------------------------------------------
export RCLONE_CONFIG_S3BACKUPTOOL_TYPE=s3
export RCLONE_CONFIG_S3BACKUPTOOL_PROVIDER=Other
export RCLONE_CONFIG_S3BACKUPTOOL_ACCESS_KEY_ID="${S3_ACCESS_KEY}"
export RCLONE_CONFIG_S3BACKUPTOOL_SECRET_ACCESS_KEY="${S3_SECRET_KEY}"
export RCLONE_CONFIG_S3BACKUPTOOL_REGION="${S3_REGION}"
export RCLONE_CONFIG_S3BACKUPTOOL_ENDPOINT="${S3_ENDPOINT}"
export RCLONE_CONFIG_S3BACKUPTOOL_NO_CHECK_BUCKET=false

# Capture the upload start time BEFORE the rclone call so the duration
# stored in upload_attempts is accurate (completed_at - started_at).
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log "Uploading ${RUN_DIR} → s3://${S3_BUCKET}/${REMOTE_DEST}"

UPLOAD_STATUS="failed"
UPLOAD_ERROR=""
BYTES_TRANSFERRED=0

# ---------------------------------------------------------------------------
# Execute rclone copy
#
# rclone copy: copies source → destination without deleting extra files at the
#   destination (unlike rclone sync which would delete files not in source).
#   This preserves any files that were manually uploaded to the same prefix.
#
# --progress           : show transfer progress in the log
# --stats-one-line     : condense stats to a single line per update interval
# --transfers=4        : parallel transfers (4 concurrent file uploads)
#
# The pipe `| while IFS= read -r line; do log "[rclone] ${line}"; done`
# prefixes every rclone output line with our timestamped [s3][rclone] tag
# so the journald log is consistent and filterable.
#
# `if rclone … ; then` captures the exit code correctly even through the pipe
# because we're testing the entire compound command, not just the pipe tail.
# ---------------------------------------------------------------------------
if rclone copy "${RUN_DIR}" "${REMOTE_PATH}:${S3_BUCKET}/${REMOTE_DEST}" \
     --progress \
     --stats-one-line \
     --transfers=4 \
     2>&1 | while IFS= read -r line; do log "[rclone] ${line}"; done; then

  log "S3 upload succeeded."
  UPLOAD_STATUS="success"

  # Approximate bytes transferred = total size of the run directory.
  # rclone's --stats output is not easily machine-parseable; du is simpler.
  # This is an approximation because rclone may skip unchanged files.
  BYTES_TRANSFERRED="$(du -sb "${RUN_DIR}" 2>/dev/null | awk '{print $1}' || echo 0)"

else
  err "rclone S3 upload failed (exit code: $?)."
  UPLOAD_STATUS="failed"
  UPLOAD_ERROR="rclone exited non-zero"
fi

# ---------------------------------------------------------------------------
# Per-file upload tracking
#
# We record one upload_attempts row per file, not one per run, so the
# dashboard can show fine-grained status: which individual files were
# uploaded successfully vs which failed.
#
# Process substitution `< <(find ...)` avoids spawning a subshell for the
# while loop, preserving variable assignments (UPLOAD_STATUS etc.) made
# inside the loop in the current shell's scope.
#
# For each file:
#   1. Query the API for the backup_files.id by (run_id, file_name).
#   2. If found (FILE_ID != 0), call db_record_upload() to insert the row.
#   3. If not found (maybe the backup script failed to record it), skip.
# ---------------------------------------------------------------------------
if [[ "${DEST_ID}" != "0" ]]; then
  log "Recording per-file upload attempts for destination ID=${DEST_ID}…"

  while IFS= read -r filepath; do
    # Look up the file record by run_id + file_name.
    # URL-encode the filename would be correct for names with spaces, but
    # backup filenames are always safe ASCII (no spaces/special chars).
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
  # -maxdepth 1: only direct children of RUN_DIR (no subdirectories).
  # -type f: regular files only (skip any directories, symlinks, sockets).
else
  log "No S3 destination found in tracking DB — skipping per-file upload records."
fi

# Exit with 0 only if the upload succeeded.
# This allows backup.sh to detect S3 failure and mark the run as "partial".
[[ "${UPLOAD_STATUS}" == "success" ]]
