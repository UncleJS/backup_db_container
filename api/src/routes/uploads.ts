import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { uploadAttempts, backupFiles, destinations } from "../db/schema";
import { eq, isNull, and, desc } from "drizzle-orm";

export const uploadsRoutes = new Elysia({ prefix: "/uploads" })
  // -------------------------------------------------------------------------
  // POST /uploads — record an upload attempt
  // -------------------------------------------------------------------------
  .post(
    "/",
    async ({ body, set }) => {
      const [result] = await db.insert(uploadAttempts).values({
        fileId: body.file_id,
        destinationId: body.destination_id,
        status: body.status as any,
        startedAt: body.started_at,
        completedAt: body.completed_at,
        bytesTransferred: body.bytes_transferred ?? 0,
        errorMessage: body.error_message,
      });
      set.status = 201;
      return { id: result.insertId };
    },
    {
      body: t.Object({
        file_id: t.Number(),
        destination_id: t.Number(),
        status: t.Union([t.Literal("pending"), t.Literal("success"), t.Literal("failed")]),
        started_at: t.String(),
        completed_at: t.Optional(t.String()),
        bytes_transferred: t.Optional(t.Number()),
        error_message: t.Optional(t.String()),
      }),
      detail: { summary: "Record upload attempt", tags: ["Uploads"] },
    }
  )

  // -------------------------------------------------------------------------
  // GET /uploads — recent upload attempts with destination info
  // -------------------------------------------------------------------------
  .get(
    "/",
    async ({ query }) => {
      const limit = Math.min(parseInt(query.limit ?? "50", 10), 200);
      const offset = parseInt(query.offset ?? "0", 10);

      const rows = await db
        .select({
          id: uploadAttempts.id,
          fileId: uploadAttempts.fileId,
          destinationId: uploadAttempts.destinationId,
          destinationName: destinations.name,
          destinationType: destinations.type,
          status: uploadAttempts.status,
          startedAt: uploadAttempts.startedAt,
          completedAt: uploadAttempts.completedAt,
          bytesTransferred: uploadAttempts.bytesTransferred,
          errorMessage: uploadAttempts.errorMessage,
          fileName: backupFiles.fileName,
          fileType: backupFiles.fileType,
        })
        .from(uploadAttempts)
        .leftJoin(destinations, eq(uploadAttempts.destinationId, destinations.id))
        .leftJoin(backupFiles, eq(uploadAttempts.fileId, backupFiles.id))
        .where(isNull(uploadAttempts.archivedAt))
        .orderBy(desc(uploadAttempts.startedAt))
        .limit(limit)
        .offset(offset);

      return { data: rows, limit, offset };
    },
    {
      query: t.Object({
        limit: t.Optional(t.String()),
        offset: t.Optional(t.String()),
      }),
      detail: { summary: "List upload attempts", tags: ["Uploads"] },
    }
  );
