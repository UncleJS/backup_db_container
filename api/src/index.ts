import { Elysia } from "elysia";
import { openapi } from "@elysiajs/openapi";
import { cors } from "@elysiajs/cors";
import { readFileSync } from "fs";
import { migrate } from "drizzle-orm/mysql2/migrator";
import { db, pool } from "./db/client";
import { withAuth } from "./auth";
import { runsRoutes } from "./routes/runs";
import { filesRoutes } from "./routes/files";
import { uploadsRoutes } from "./routes/uploads";
import { destinationsRoutes } from "./routes/destinations";
import { scheduleRoutes } from "./routes/schedule";
import { settingsRoutes } from "./routes/settings";
import { statsRoutes } from "./routes/stats";
import { triggerRoutes } from "./routes/trigger";
import { retentionRoutes } from "./routes/retention";
import { healthRoutes } from "./routes/health";
import { DEFAULT_SETTINGS } from "./routes/settings";
import { settings, scheduleConfig } from "./db/schema";
import { isNull, eq, and } from "drizzle-orm";

const PORT = parseInt(process.env.API_PORT ?? "3001", 10);

// ---------------------------------------------------------------------------
// Seed default settings if not yet present
// ---------------------------------------------------------------------------
async function seedDefaults() {
  const now = new Date().toISOString().replace("T", " ").substring(0, 19);

  for (const [key, value] of Object.entries(DEFAULT_SETTINGS)) {
    const [existing] = await db
      .select()
      .from(settings)
      .where(and(eq(settings.key, key), isNull(settings.archivedAt)));
    if (!existing) {
      await db.insert(settings).values({ key, value, updatedAt: now });
    }
  }

  // Seed schedule_config singleton if missing
  const [sc] = await db.select().from(scheduleConfig).where(eq(scheduleConfig.id, 1));
  if (!sc) {
    await db.insert(scheduleConfig).values({
      id: 1,
      cronExpression: "0 2 * * *",
      enabled: false,
      backupMode: "full",
      lastModifiedAt: now,
      modifiedBy: "system",
    });
  }
}

// ---------------------------------------------------------------------------
// Run migrations and seed, then start
// ---------------------------------------------------------------------------
async function bootstrap() {
  console.log("[api] Running DB migrations...");
  try {
    await migrate(db as any, { migrationsFolder: "./src/db/migrations" });
    console.log("[api] Migrations applied.");
  } catch (err) {
    console.error("[api] Migration error:", err);
    // Non-fatal in dev — tables may already exist
  }

  await seedDefaults();
  console.log("[api] Default settings seeded.");

  const app = new Elysia()
    .use(
      openapi({
        documentation: {
          info: {
            title: "Backup Tool API",
            version: "1.0.0",
            description:
              "REST API for the backup-db-container tool. Tracks backup runs, files, uploads, schedules, and settings.",
          },
          tags: [
            { name: "Runs", description: "Backup run lifecycle" },
            { name: "Files", description: "Files produced by backup runs" },
            { name: "Uploads", description: "S3/SFTP upload attempts" },
            { name: "Destinations", description: "S3/SFTP destination management" },
            { name: "Schedule", description: "Backup schedule config" },
            { name: "Settings", description: "Backup settings key-value store" },
            { name: "Stats", description: "Aggregate statistics for dashboard" },
            { name: "Trigger", description: "Manual backup trigger" },
            { name: "Retention", description: "Pruning/retention audit log" },
            { name: "Health", description: "System health checks" },
          ],
        },
      })
    )
    .use(
      cors({
        origin: process.env.DASHBOARD_ORIGIN ?? "http://localhost:3000",
        credentials: true,
      })
    )
    // Health check is public (no auth) — used by dashboard /health page and load balancers
    .use(healthRoutes)
    // All other routes require the internal shared secret
    .use(withAuth)
    .use(runsRoutes)
    .use(filesRoutes)
    .use(uploadsRoutes)
    .use(destinationsRoutes)
    .use(scheduleRoutes)
    .use(settingsRoutes)
    .use(statsRoutes)
    .use(triggerRoutes)
    .use(retentionRoutes)
    .listen(PORT);

  console.log(`[api] Backup Tool API running on http://0.0.0.0:${PORT}`);
  console.log(`[api] Swagger UI → http://0.0.0.0:${PORT}/swagger`);
}

bootstrap().catch((err) => {
  console.error("[api] Fatal startup error:", err);
  process.exit(1);
});
