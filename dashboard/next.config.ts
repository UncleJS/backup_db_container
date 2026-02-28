import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  // API_INTERNAL_URL is read server-side only (no NEXT_PUBLIC_ prefix).
  // It is never injected into the client bundle.
  // Set it via the backup-dashboard.container Environment= line or .env.local.
};

export default nextConfig;
