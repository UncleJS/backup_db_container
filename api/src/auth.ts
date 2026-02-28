import { Elysia } from "elysia";
import { readFileSync } from "fs";

// Read the shared internal secret from Podman secret mount (or env for local dev)
function loadSecret(): string {
  const secretPath = "/run/secrets/internal_api_secret";
  try {
    return readFileSync(secretPath, "utf-8").trim();
  } catch {
    const envSecret = process.env.INTERNAL_API_SECRET ?? "";
    if (!envSecret) {
      console.warn(
        "[auth] WARNING: internal_api_secret not found at /run/secrets/ and INTERNAL_API_SECRET env is empty. All API calls will be rejected."
      );
    }
    return envSecret;
  }
}

const INTERNAL_SECRET = loadSecret();

export const withAuth = new Elysia({ name: "auth" }).derive(
  { as: "global" },
  ({ headers, set }) => {
    const auth = headers["authorization"] ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";

    if (!INTERNAL_SECRET || token !== INTERNAL_SECRET) {
      set.status = 401;
      throw new Error("Unauthorized");
    }

    return {};
  }
);
