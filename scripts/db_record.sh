#!/usr/bin/env bash
# =============================================================================
# scripts/db_record.sh — Tracking DB helper library (sourced, not executed)
#
# PURPOSE
#   Provides shell functions that wrap the Elysia tracking API so that backup
#   scripts can record runs, files, uploads, and retention events without
#   directly accessing the MariaDB socket.  All communication goes through the
#   HTTP API using the internal shared secret for authentication.
#
# WHY AN HTTP API INSTEAD OF DIRECT DB ACCESS?
#   • The tracking DB is in a separate container.  Shell scripts would need the
#     mysql CLI and connection credentials to reach it directly.
#   • Going through the API means all DB writes go through Drizzle ORM, which
#     enforces the schema and handles connection pooling.
#   • The API is the single source of truth; any future schema changes only
#     need updating in one place (api/src/db/schema.ts), not in shell strings.
#
# AUTHENTICATION
#   All API calls use an HTTP Bearer token: the INTERNAL_API_SECRET env var.
#   This secret is shared between the API container and the agent container
#   via Podman secrets.  The dashboard NEVER exposes this secret to browsers;
#   it makes its own server-side requests to the API using the same secret.
#
# HOW TO USE
#   Source this file from another script before calling any function:
#     source "${SCRIPT_DIR}/db_record.sh"
#   The caller must have API_BASE_URL and INTERNAL_API_SECRET in the environment.
#   Both are passed as positional args to backup.sh and forwarded via env vars.
#
# ENVIRONMENT VARIABLES EXPECTED BY ALL FUNCTIONS
#   API_BASE_URL          — base URL of the Elysia API (e.g. http://localhost:3001)
#   INTERNAL_API_SECRET   — Bearer token used in Authorization header
#
# ERROR HANDLING
#   All functions treat API failures as non-fatal by default (|| true).
#   A failed API call is logged to stderr but does not abort the backup run.
#   The backup data is more important than the tracking record.  The exception
#   is db_create_run(), which returns "0" on failure — callers should check.
# =============================================================================

# ---------------------------------------------------------------------------
# db_api()
#   Low-level wrapper around curl for all API calls.
#
#   Parameters:
#     $1  method  — HTTP method (GET, POST, PATCH, etc.)
#     $2  path    — API path starting with "/" (e.g. "/runs")
#     $3  body    — optional JSON request body string
#
#   Returns: the response body (stdout)
#   Exit code: 0 on success, non-zero on HTTP or network error
#
#   curl flags used:
#     -s   : silent (no progress meter)
#     -f   : fail silently on server errors (return non-zero on 4xx/5xx)
#     -X   : HTTP method
#     -H   : request headers (Content-Type + Authorization Bearer)
#     -d   : request body (only sent when $body is non-empty)
#   Stderr is redirected to /dev/null because the API returns structured JSON
#   errors; curl noise would pollute the backup log.
# ---------------------------------------------------------------------------
db_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"   # optional; empty string → no -d flag, no Content-Type

  # Construct the full URL by concatenating base + path.
  # Falls back to localhost:3001 if API_BASE_URL is unset (should not happen
  # in production but guards against accidental direct invocation).
  local url="${API_BASE_URL:-http://localhost:3001}${path}"
  local secret="${INTERNAL_API_SECRET:-}"

  if [[ -n "${body}" ]]; then
    # Send JSON body — include Content-Type header so Elysia parses it.
    curl -sf -X "${method}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${secret}" \
      -d "${body}" \
      "${url}" 2>/dev/null
  else
    # No body — GET, DELETE, or body-less PATCH.
    curl -sf -X "${method}" \
      -H "Authorization: Bearer ${secret}" \
      "${url}" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# db_create_run()
#   Create a new backup_runs record at the start of a backup run.
#   Returns the new run ID (integer) on stdout so callers can capture it:
#     RUN_ID="$(db_create_run scheduled full)"
#
#   On API failure, returns "0" so callers can detect the error condition
#   without aborting the backup (0 is used as a sentinel "no ID" value).
#
#   Parameters:
#     $1  trigger_type   — "scheduled" | "manual"
#     $2  backup_mode    — "full" | "incremental"
#
#   Side effects: writes a row to backup_runs with status="running"
# ---------------------------------------------------------------------------
db_create_run() {
  local trigger_type="$1"
  local backup_mode="$2"

  # Capture current UTC timestamp in ISO-8601 format with Z suffix.
  # The Z (Zulu) suffix explicitly marks it as UTC so the API / dashboard
  # can parse it unambiguously regardless of the container's timezone.
  local started_at
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local response
  # POST to /runs; on curl failure the `|| { echo "0"; return 1; }` ensures
  # we still emit "0" to stdout so the caller's $() capture gets a usable value.
  response="$(db_api POST "/runs" \
    "{\"trigger_type\":\"${trigger_type}\",\"backup_mode\":\"${backup_mode}\",\"started_at\":\"${started_at}\",\"status\":\"running\"}")" \
    || { echo "0"; return 1; }

  # Extract the id field from the JSON response.
  # `jq -r '.id // 0'`:
  #   -r         : raw output (no surrounding quotes)
  #   .id        : access the "id" key
  #   // 0       : alternative operator — if .id is null/absent, return 0
  echo "${response}" | jq -r '.id // 0'
}

# ---------------------------------------------------------------------------
# db_complete_run()
#   Update an existing backup_runs record when the run finishes.
#   Called by backup.sh at the very end (success or failure).
#
#   Parameters:
#     $1  run_id        — integer ID from db_create_run()
#     $2  status        — "success" | "failed" | "partial"
#     $3  total_size    — total bytes backed up (integer)
#     $4  error_msg     — (optional) human-readable error description
#
#   Side effects: PATCHes the backup_runs row; sets completed_at to now (UTC)
#   Non-fatal: `> /dev/null || true` absorbs curl errors silently
# ---------------------------------------------------------------------------
db_complete_run() {
  local run_id="$1"
  local status="$2"
  local total_size="$3"
  local error_msg="${4:-}"   # optional; empty string if run succeeded

  local completed_at
  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # `echo "${error_msg}" | jq -Rs .`
  #   -R : read raw input (don't try to parse as JSON)
  #   -s : slurp all input into a single string (handles multi-line messages)
  #   .  : output the string as a JSON-encoded value (adds quotes, escapes
  #        backslashes, newlines, etc.)
  # Result: a JSON string literal safe to embed directly in the JSON body.
  # Example: "line1\nline2" → "\"line1\\nline2\""
  db_api PATCH "/runs/${run_id}" \
    "{\"status\":\"${status}\",\"total_size_bytes\":${total_size},\"completed_at\":\"${completed_at}\",\"error_message\":$(echo "${error_msg}" | jq -Rs .)}" \
    > /dev/null || true
}

# ---------------------------------------------------------------------------
# db_record_file()
#   Create a backup_files record for one file produced during a backup run.
#   Returns the new file ID on stdout (used by upload scripts to link uploads).
#
#   Parameters:
#     $1  run_id      — integer ID from db_create_run()
#     $2  file_path   — absolute path to the file inside the container
#     $3  file_type   — "mariadb-backup" | "dump" | "volume" | "config"
#
#   How size and checksum are obtained:
#     stat -c%s         — byte count without reading the file content
#     sha256sum         — SHA-256 hex digest for integrity verification;
#                         the `| awk '{print $1}'` strips the filename column
#                         from sha256sum's "<hash>  <file>" output format
#
#   `jq -Rs .` is used for file_name, file_path, and checksum to ensure any
#   special characters (spaces, backslashes, Unicode) are safely JSON-encoded.
# ---------------------------------------------------------------------------
db_record_file() {
  local run_id="$1"
  local file_path="$2"
  local file_type="$3"   # mariadb-backup | dump | volume | config

  # Get file size — if stat fails (file missing), default to 0.
  local size_bytes
  size_bytes="$(stat -c%s "${file_path}" 2>/dev/null || echo 0)"

  # Compute SHA-256 checksum — if sha256sum fails, default to empty string.
  # The checksum is stored in the DB so the dashboard can detect corruption.
  local checksum
  checksum="$(sha256sum "${file_path}" 2>/dev/null | awk '{print $1}' || echo "")"

  # Derive filename from path — the API also stores the full path but the
  # filename is useful for display and filtering.
  local file_name
  file_name="$(basename "${file_path}")"

  # POST to /files; return the new ID (or 0 on failure).
  # `jq -Rs .` wraps each string value in proper JSON quoting.
  db_api POST "/files" \
    "{\"run_id\":${run_id},\"file_name\":$(echo "${file_name}" | jq -Rs .),\"file_path\":$(echo "${file_path}" | jq -Rs .),\"file_type\":\"${file_type}\",\"size_bytes\":${size_bytes},\"checksum_sha256\":$(echo "${checksum}" | jq -Rs .)}" \
    2>/dev/null | jq -r '.id // 0'
}

# ---------------------------------------------------------------------------
# db_record_upload()
#   Create an upload_attempts record for a file→destination upload attempt.
#   Called by upload_s3.sh and upload_sftp.sh after each file's upload.
#
#   Parameters:
#     $1  file_id           — integer ID from db_record_file()
#     $2  destination_id    — integer ID from the destinations table
#     $3  status            — "pending" | "success" | "failed"
#     $4  bytes_transferred — (optional) bytes actually sent; 0 if unknown
#     $5  error_msg         — (optional) error description; empty on success
#     $6  started_at        — ISO-8601 UTC timestamp when upload began;
#                             captured before the rclone call so duration
#                             (completed_at − started_at) is accurate
#
#   Side effects: inserts a row in upload_attempts; sets completed_at to now
#   Non-fatal: `> /dev/null || true`
# ---------------------------------------------------------------------------
db_record_upload() {
  local file_id="$1"
  local destination_id="$2"
  local status="$3"        # pending | success | failed
  local bytes_transferred="${4:-0}"
  local error_msg="${5:-}"
  local started_at="$6"    # captured by caller before the upload

  local completed_at
  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  db_api POST "/uploads" \
    "{\"file_id\":${file_id},\"destination_id\":${destination_id},\"status\":\"${status}\",\"bytes_transferred\":${bytes_transferred},\"started_at\":\"${started_at}\",\"completed_at\":\"${completed_at}\",\"error_message\":$(echo "${error_msg}" | jq -Rs .)}" \
    > /dev/null || true
}

# ---------------------------------------------------------------------------
# db_record_retention()
#   Create a retention_events record when prune.sh deletes a backup file.
#   Preserves audit history of what was deleted, when, and why.
#
#   Parameters:
#     $1  file_path        — absolute path of the deleted file
#     $2  file_size        — size in bytes at the time of deletion
#     $3  retention_days   — the retention policy value that triggered deletion
#                            (e.g. "30" if files older than 30 days are pruned)
#
#   reason is hard-coded to "age_exceeded" — the only deletion reason today.
#   Future reasons (quota_exceeded, manual_purge) could be added as a $4 arg.
#   Non-fatal: `> /dev/null || true`
# ---------------------------------------------------------------------------
db_record_retention() {
  local file_path="$1"
  local file_size="$2"
  local retention_days="$3"

  local deleted_at
  deleted_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  db_api POST "/retention-events" \
    "{\"file_path\":$(echo "${file_path}" | jq -Rs .),\"file_size_bytes\":${file_size},\"deleted_at\":\"${deleted_at}\",\"reason\":\"age_exceeded\",\"retention_days_at_deletion\":${retention_days}}" \
    > /dev/null || true
}
