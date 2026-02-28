import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { backupFiles } from "../db/schema";
import { eq, isNull, and, sql } from "drizzle-orm";

export const filesRoutes = new Elysia({ prefix: "/files" })
  // -------------------------------------------------------------------------
  // POST /files — record a produced backup file
  // -------------------------------------------------------------------------
  .post(
    "/",
    async ({ body, set }) => {
      const [result] = await db.insert(backupFiles).values({
        runId: body.run_id,
        fileName: body.file_name,
        filePath: body.file_path,
        fileType: body.file_type as any,
        sizeBytes: body.size_bytes ?? 0,
        checksumSha256: body.checksum_sha256,
      });
      set.status = 201;
      return { id: result.insertId };
    },
    {
      body: t.Object({
        run_id: t.Number(),
        file_name: t.String(),
        file_path: t.String(),
        file_type: t.Union([
          t.Literal("mariadb-backup"),
          t.Literal("dump"),
          t.Literal("volume"),
          t.Literal("config"),
        ]),
        size_bytes: t.Optional(t.Number()),
        checksum_sha256: t.Optional(t.String()),
      }),
      detail: { summary: "Record backup file", tags: ["Files"] },
    }
  )

  // -------------------------------------------------------------------------
  // GET /files — query files by run_id and/or file_name
  // -------------------------------------------------------------------------
  .get(
    "/",
    async ({ query }) => {
      const conditions = [isNull(backupFiles.archivedAt)];
      if (query.run_id) conditions.push(eq(backupFiles.runId, parseInt(query.run_id, 10)));
      if (query.file_name) conditions.push(eq(backupFiles.fileName, query.file_name));

      return db.select().from(backupFiles).where(and(...conditions));
    },
    {
      query: t.Object({
        run_id: t.Optional(t.String()),
        file_name: t.Optional(t.String()),
      }),
      detail: { summary: "List backup files", tags: ["Files"] },
    }
  )

  // -------------------------------------------------------------------------
  // GET /files/run/:run_id — all files for a specific run
  // -------------------------------------------------------------------------
  .get(
    "/run/:run_id",
    async ({ params }) => {
      return db
        .select()
        .from(backupFiles)
        .where(and(eq(backupFiles.runId, parseInt(params.run_id, 10)), isNull(backupFiles.archivedAt)));
    },
    {
      params: t.Object({ run_id: t.String() }),
      detail: { summary: "Get files for a run", tags: ["Files"] },
    }
  );
