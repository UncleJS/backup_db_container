import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { settings } from "../db/schema";
import { eq, isNull, and, sql } from "drizzle-orm";

// Default settings applied on first startup
export const DEFAULT_SETTINGS: Record<string, string> = {
  retention_days: "7",
  backup_mariadb: "true",
  backup_volumes: "true",
  backup_configs: "true",
  podman_volumes: "",
  compression: "gzip",
};

export const settingsRoutes = new Elysia({ prefix: "/settings" })
  // -------------------------------------------------------------------------
  // GET /settings — return all active settings as key-value object
  // -------------------------------------------------------------------------
  .get("/", async () => {
    const rows = await db
      .select()
      .from(settings)
      .where(isNull(settings.archivedAt));

    const result: Record<string, string> = { ...DEFAULT_SETTINGS };
    for (const row of rows) {
      result[row.key] = row.value ?? "";
    }
    return result;
  }, { detail: { summary: "Get all settings", tags: ["Settings"] } })

  // -------------------------------------------------------------------------
  // PUT /settings — bulk upsert of key-value pairs
  // -------------------------------------------------------------------------
  .put(
    "/",
    async ({ body }) => {
      const now = new Date().toISOString().replace("T", " ").substring(0, 19);

      for (const [key, value] of Object.entries(body)) {
        const [existing] = await db
          .select()
          .from(settings)
          .where(and(eq(settings.key, key), isNull(settings.archivedAt)));

        if (existing) {
          await db.update(settings)
            .set({ value: String(value), updatedAt: now })
            .where(eq(settings.id, existing.id));
        } else {
          await db.insert(settings).values({ key, value: String(value), updatedAt: now });
        }
      }

      return { updated: Object.keys(body).length };
    },
    {
      body: t.Record(t.String(), t.Any()),
      detail: { summary: "Update settings (key-value)", tags: ["Settings"] },
    }
  );
