#!/bin/sh
# =============================================================================
# entrypoint.dashboard.sh
# Reads Podman secrets into environment variables, then starts Next.js.
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Internal shared secret (Next.js → Elysia API auth)
# ---------------------------------------------------------------------------
if [ -f /run/secrets/internal_api_secret ]; then
  export INTERNAL_API_SECRET="$(cat /run/secrets/internal_api_secret)"
fi

# ---------------------------------------------------------------------------
# Session signing secret (httpOnly cookie JWT)
# ---------------------------------------------------------------------------
if [ -f /run/secrets/dashboard_session_secret ]; then
  export SESSION_SECRET="$(cat /run/secrets/dashboard_session_secret)"
fi

# ---------------------------------------------------------------------------
# Admin password (plaintext or bcrypt hash supported)
# ---------------------------------------------------------------------------
if [ -f /run/secrets/dashboard_admin_password ]; then
  export ADMIN_PASSWORD="$(cat /run/secrets/dashboard_admin_password)"
fi

# ---------------------------------------------------------------------------
# Start Next.js
# ---------------------------------------------------------------------------
exec node server.js
