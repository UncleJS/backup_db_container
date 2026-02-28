/**
 * Shared JWT secret key helper.
 *
 * Used by both:
 *   - src/lib/session.ts  (server-only: sign + verify session cookies)
 *   - src/middleware.ts   (Edge: verify session cookies on every request)
 *
 * Reads SESSION_SECRET → DASHBOARD_SESSION_SECRET → hard-coded fallback.
 * The fallback is intentionally weak so the app starts in dev without
 * configuration, but emits a warning so operators know to set the secret.
 */
export function getSecretKey(): Uint8Array {
  const secret =
    process.env.SESSION_SECRET ??
    process.env.DASHBOARD_SESSION_SECRET ??
    "change-me-in-production-32-chars!!";

  if (
    process.env.NODE_ENV === "production" &&
    secret === "change-me-in-production-32-chars!!"
  ) {
    console.warn(
      "[session] WARNING: Using default SESSION_SECRET in production. " +
        "Set SESSION_SECRET (or DASHBOARD_SESSION_SECRET) via Podman secret."
    );
  }

  return new TextEncoder().encode(secret);
}
