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
  // PUT /settings — bulk upsert of key-value pairs (archive-on-change)
  //
  // For each key:
  //   • If no active row exists → INSERT new row
  //   • If an active row exists AND the value is different → archive the old
  //     row (set archivedAt) then INSERT a new row.  This preserves the full
  //     audit trail of every value a setting has ever had.
  //   • If the value is identical → no-op (avoid spurious archive rows)
  // -------------------------------------------------------------------------
  .put(
    "/",
    async ({ body }) => {
      const now = new Date().toISOString().replace("T", " ").substring(0, 19);

      let updated = 0;
      for (const [key, value] of Object.entries(body)) {
        const strValue = String(value);

        const [existing] = await db
          .select()
          .from(settings)
          .where(and(eq(settings.key, key), isNull(settings.archivedAt)));

        if (existing) {
          if (existing.value === strValue) {
            // Value unchanged — skip entirely to avoid polluting the audit log
            continue;
          }
          // Archive the current active row before inserting the new value
          await db
            .update(settings)
            .set({ archivedAt: now })
            .where(eq(settings.id, existing.id));
        }

        // Insert the new active row
        await db.insert(settings).values({ key, value: strValue, updatedAt: now });
        updated++;
      }

      return { updated };
    },
    {
      body: t.Record(t.String(), t.Any()),
      detail: { summary: "Update settings (key-value)", tags: ["Settings"] },
    }
  );
