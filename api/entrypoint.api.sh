#!/bin/sh
# =============================================================================
# entrypoint.api.sh — Load Podman secrets into env vars before starting API
# Secrets are mounted as files at /run/secrets/<name>
# =============================================================================
set -e

read_secret() {
  local name="$1"
  local path="/run/secrets/${name}"
  if [ -f "${path}" ]; then cat "${path}"; else echo ""; fi
}

export TRACKING_DB_PASSWORD="$(read_secret tracking_db_password)"
export INTERNAL_API_SECRET="$(read_secret internal_api_secret)"

exec bun run src/index.ts
