import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { scheduleConfig } from "../db/schema";
import { eq, sql } from "drizzle-orm";

export const scheduleRoutes = new Elysia({ prefix: "/schedule" })
  // -------------------------------------------------------------------------
  // GET /schedule
  // -------------------------------------------------------------------------
  .get("/", async () => {
    const rows = await db.select().from(scheduleConfig).where(eq(scheduleConfig.id, 1));
    if (rows.length === 0) {
      // Return defaults if no row exists yet
      return {
        id: 1,
        cron_expression: "0 2 * * *",
        enabled: false,
        backup_mode: "full",
        last_modified_at: null,
        modified_by: "system",
      };
    }
    const r = rows[0]!;
    return {
      id: r.id,
      cron_expression: r.cronExpression,
      enabled: r.enabled,
      backup_mode: r.backupMode,
      last_modified_at: r.lastModifiedAt,
      modified_by: r.modifiedBy,
    };
  }, { detail: { summary: "Get schedule config", tags: ["Schedule"] } })

  // -------------------------------------------------------------------------
  // PUT /schedule — upsert (id = 1 always)
  // -------------------------------------------------------------------------
  .put(
    "/",
    async ({ body }) => {
      const now = new Date().toISOString().replace("T", " ").substring(0, 19);
      await db
        .insert(scheduleConfig)
        .values({
          id: 1,
          cronExpression: body.cron_expression ?? "0 2 * * *",
          enabled: body.enabled ?? false,
          backupMode: (body.backup_mode as any) ?? "full",
          lastModifiedAt: now,
          modifiedBy: body.modified_by ?? "dashboard",
        })
        .onDuplicateKeyUpdate({
          set: {
            cronExpression: sql`VALUES(cron_expression)`,
            enabled: sql`VALUES(enabled)`,
            backupMode: sql`VALUES(backup_mode)`,
            lastModifiedAt: now,
            modifiedBy: body.modified_by ?? "dashboard",
          },
        });

      return { updated: true };
    },
    {
      body: t.Object({
        cron_expression: t.Optional(t.String()),
        enabled: t.Optional(t.Boolean()),
        backup_mode: t.Optional(t.Union([t.Literal("full"), t.Literal("incremental")])),
        modified_by: t.Optional(t.String()),
      }),
      detail: { summary: "Update schedule config", tags: ["Schedule"] },
    }
  );
