import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { retentionEvents } from "../db/schema";
import { sql } from "drizzle-orm";

export const retentionRoutes = new Elysia({ prefix: "/retention-events" })
  .post(
    "/",
    async ({ body, set }) => {
      const [result] = await db.insert(retentionEvents).values({
        filePath: body.file_path,
        fileSizeBytes: body.file_size_bytes ?? 0,
        deletedAt: body.deleted_at,
        reason: (body.reason as any) ?? "age_exceeded",
        retentionDaysAtDeletion: body.retention_days_at_deletion,
      });
      set.status = 201;
      return { id: result.insertId };
    },
    {
      body: t.Object({
        file_path: t.String(),
        file_size_bytes: t.Optional(t.Number()),
        deleted_at: t.String(),
        reason: t.Optional(t.String()),
        retention_days_at_deletion: t.Number(),
      }),
      detail: { summary: "Record retention/pruning event", tags: ["Retention"] },
    }
  )

  .get(
    "/",
    async ({ query }) => {
      const limit = Math.min(parseInt(query.limit ?? "50", 10), 200);
      const offset = parseInt(query.offset ?? "0", 10);

      const rows = await db
        .select()
        .from(retentionEvents)
        .orderBy(sql`deleted_at DESC`)
        .limit(limit)
        .offset(offset);

      return { data: rows, limit, offset };
    },
    {
      query: t.Object({
        limit: t.Optional(t.String()),
        offset: t.Optional(t.String()),
      }),
      detail: { summary: "List retention events", tags: ["Retention"] },
    }
  );
