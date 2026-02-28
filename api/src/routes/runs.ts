import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { backupRuns } from "../db/schema";
import { desc, eq, isNull, and, sql } from "drizzle-orm";

export const runsRoutes = new Elysia({ prefix: "/runs" })
  // -------------------------------------------------------------------------
  // POST /runs — create a new run record (called by backup agent)
  // -------------------------------------------------------------------------
  .post(
    "/",
    async ({ body, set }) => {
      const [result] = await db.insert(backupRuns).values({
        triggerType: body.trigger_type,
        backupMode: body.backup_mode,
        status: "running",
        startedAt: body.started_at,
      });
      set.status = 201;
      return { id: result.insertId };
    },
    {
      body: t.Object({
        trigger_type: t.Union([t.Literal("scheduled"), t.Literal("manual")]),
        backup_mode: t.Union([t.Literal("full"), t.Literal("incremental")]),
        started_at: t.String(),
        status: t.Optional(t.String()),
      }),
      detail: { summary: "Create backup run", tags: ["Runs"] },
    }
  )

  // -------------------------------------------------------------------------
  // GET /runs — paginated list of backup runs
  // -------------------------------------------------------------------------
  .get(
    "/",
    async ({ query }) => {
      const limit = Math.min(parseInt(query.limit ?? "50", 10), 200);
      const offset = parseInt(query.offset ?? "0", 10);

      const rows = await db
        .select()
        .from(backupRuns)
        .where(isNull(backupRuns.archivedAt))
        .orderBy(desc(backupRuns.startedAt))
        .limit(limit)
        .offset(offset);

      const [{ total }] = await db
        .select({ total: sql<number>`count(*)` })
        .from(backupRuns)
        .where(isNull(backupRuns.archivedAt));

      return { data: rows, total, limit, offset };
    },
    {
      query: t.Object({
        limit: t.Optional(t.String()),
        offset: t.Optional(t.String()),
      }),
      detail: { summary: "List backup runs", tags: ["Runs"] },
    }
  )

  // -------------------------------------------------------------------------
  // GET /runs/:id — single run detail
  // -------------------------------------------------------------------------
  .get(
    "/:id",
    async ({ params, set }) => {
      const [row] = await db
        .select()
        .from(backupRuns)
        .where(and(eq(backupRuns.id, parseInt(params.id, 10)), isNull(backupRuns.archivedAt)));

      if (!row) { set.status = 404; return { error: "Run not found" }; }
      return row;
    },
    {
      params: t.Object({ id: t.String() }),
      detail: { summary: "Get backup run by ID", tags: ["Runs"] },
    }
  )

  // -------------------------------------------------------------------------
  // PATCH /runs/:id — update run status/size/completion (called by agent)
  // -------------------------------------------------------------------------
  .patch(
    "/:id",
    async ({ params, body, set }) => {
      const id = parseInt(params.id, 10);
      const [existing] = await db.select().from(backupRuns).where(eq(backupRuns.id, id));
      if (!existing) { set.status = 404; return { error: "Run not found" }; }

      // Calculate duration if completed_at is being set
      let durationSeconds: number | undefined;
      if (body.completed_at && existing.startedAt) {
        const start = new Date(existing.startedAt).getTime();
        const end = new Date(body.completed_at).getTime();
        durationSeconds = Math.round((end - start) / 1000);
      }

      await db.update(backupRuns)
        .set({
          status: body.status as any,
          totalSizeBytes: body.total_size_bytes,
          completedAt: body.completed_at,
          errorMessage: body.error_message,
          ...(durationSeconds !== undefined && { durationSeconds }),
        })
        .where(eq(backupRuns.id, id));

      return { id };
    },
    {
      params: t.Object({ id: t.String() }),
      body: t.Object({
        status: t.Optional(t.String()),
        total_size_bytes: t.Optional(t.Number()),
        completed_at: t.Optional(t.String()),
        error_message: t.Optional(t.String()),
      }),
      detail: { summary: "Update backup run", tags: ["Runs"] },
    }
  );
