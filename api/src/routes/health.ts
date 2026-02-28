import { Elysia } from "elysia";
import { db } from "../db/client";
import { sql } from "drizzle-orm";

interface HealthCheck {
  name: string;
  status: "ok" | "degraded" | "unreachable";
  latency_ms?: number;
  error?: string;
}

async function checkDb(): Promise<HealthCheck> {
  const start = Date.now();
  try {
    await db.execute(sql`SELECT 1`);
    return { name: "tracking_db", status: "ok", latency_ms: Date.now() - start };
  } catch (err) {
    return { name: "tracking_db", status: "unreachable", error: String(err) };
  }
}

async function checkS3(): Promise<HealthCheck> {
  const enabled = process.env.S3_ENABLED === "true";
  if (!enabled) return { name: "s3", status: "ok" };

  const endpoint = process.env.S3_ENDPOINT ?? "https://s3.amazonaws.com";
  const start = Date.now();
  try {
    const res = await fetch(endpoint, { method: "HEAD", signal: AbortSignal.timeout(5000) });
    return {
      name: "s3",
      status: res.ok || res.status < 500 ? "ok" : "degraded",
      latency_ms: Date.now() - start,
    };
  } catch (err) {
    return { name: "s3", status: "unreachable", error: String(err) };
  }
}

async function checkSftp(): Promise<HealthCheck> {
  const enabled = process.env.SFTP_ENABLED === "true";
  if (!enabled) return { name: "sftp", status: "ok" };

  const host = process.env.SFTP_HOST ?? "";
  const port = parseInt(process.env.SFTP_PORT ?? "22", 10);
  const start = Date.now();
  try {
    // TCP reachability check via Bun's net (just opens and closes)
    const conn = await Bun.connect({
      hostname: host,
      port,
      socket: {
        open() {},
        data() {},
        close() {},
        error() {},
      },
    });
    conn.end();
    return { name: "sftp", status: "ok", latency_ms: Date.now() - start };
  } catch (err) {
    return { name: "sftp", status: "unreachable", error: String(err) };
  }
}

async function checkSourceMariadb(): Promise<HealthCheck> {
  const host = process.env.MARIADB_HOST;
  if (!host) return { name: "source_mariadb", status: "ok" };
  const port = parseInt(process.env.MARIADB_PORT ?? "3306", 10);
  const start = Date.now();
  try {
    const conn = await Bun.connect({
      hostname: host,
      port,
      socket: {
        open() {},
        data() {},
        close() {},
        error() {},
      },
    });
    conn.end();
    return { name: "source_mariadb", status: "ok", latency_ms: Date.now() - start };
  } catch (err) {
    return { name: "source_mariadb", status: "unreachable", error: String(err) };
  }
}

export const healthRoutes = new Elysia({ prefix: "/health" }).get(
  "/",
  async ({ set }) => {
    const checks = await Promise.all([
      checkDb(),
      checkS3(),
      checkSftp(),
      checkSourceMariadb(),
    ]);

    const overall = checks.every((c) => c.status === "ok")
      ? "ok"
      : checks.some((c) => c.status === "unreachable")
      ? "degraded"
      : "ok";

    if (overall !== "ok") set.status = 503;

    return {
      status: overall,
      timestamp: new Date().toISOString(),
      checks,
    };
  },
  { detail: { summary: "System health check", tags: ["Health"] } }
);
