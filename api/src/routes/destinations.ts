import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { destinations } from "../db/schema";
import { eq, isNull, and } from "drizzle-orm";

export const destinationsRoutes = new Elysia({ prefix: "/destinations" })
  // -------------------------------------------------------------------------
  // GET /destinations
  // -------------------------------------------------------------------------
  .get(
    "/",
    async ({ query }) => {
      const conditions = [isNull(destinations.archivedAt)];
      if (query.type) conditions.push(eq(destinations.type, query.type as any));
      if (query.enabled !== undefined) {
        conditions.push(eq(destinations.enabled, query.enabled === "true"));
      }
      return db.select().from(destinations).where(and(...conditions));
    },
    {
      query: t.Object({
        type: t.Optional(t.String()),
        enabled: t.Optional(t.String()),
      }),
      detail: { summary: "List destinations", tags: ["Destinations"] },
    }
  )

  // -------------------------------------------------------------------------
  // POST /destinations
  // -------------------------------------------------------------------------
  .post(
    "/",
    async ({ body, set }) => {
      const [result] = await db.insert(destinations).values({
        name: body.name,
        type: body.type as any,
        enabled: body.enabled ?? true,
        hostOrEndpoint: body.host_or_endpoint,
        port: body.port,
        bucketOrPath: body.bucket_or_path,
        accessKeyOrUser: body.access_key_or_user,
        secretName: body.secret_name,
        region: body.region,
        pathPrefix: body.path_prefix,
        sftpAuthType: body.sftp_auth_type as any,
      });
      set.status = 201;
      return { id: result.insertId };
    },
    {
      body: t.Object({
        name: t.String(),
        type: t.Union([t.Literal("s3"), t.Literal("sftp")]),
        enabled: t.Optional(t.Boolean()),
        host_or_endpoint: t.Optional(t.String()),
        port: t.Optional(t.Number()),
        bucket_or_path: t.Optional(t.String()),
        access_key_or_user: t.Optional(t.String()),
        secret_name: t.Optional(t.String()),
        region: t.Optional(t.String()),
        path_prefix: t.Optional(t.String()),
        sftp_auth_type: t.Optional(t.Union([t.Literal("password"), t.Literal("key")])),
      }),
      detail: { summary: "Add destination", tags: ["Destinations"] },
    }
  )

  // -------------------------------------------------------------------------
  // PUT /destinations/:id
  // -------------------------------------------------------------------------
  .put(
    "/:id",
    async ({ params, body, set }) => {
      const id = parseInt(params.id, 10);
      const [existing] = await db.select().from(destinations).where(eq(destinations.id, id));
      if (!existing) { set.status = 404; return { error: "Destination not found" }; }

      await db.update(destinations).set({
        name: body.name ?? existing.name,
        enabled: body.enabled ?? existing.enabled,
        hostOrEndpoint: body.host_or_endpoint ?? existing.hostOrEndpoint,
        port: body.port ?? existing.port,
        bucketOrPath: body.bucket_or_path ?? existing.bucketOrPath,
        accessKeyOrUser: body.access_key_or_user ?? existing.accessKeyOrUser,
        secretName: body.secret_name ?? existing.secretName,
        region: body.region ?? existing.region,
        pathPrefix: body.path_prefix ?? existing.pathPrefix,
        sftpAuthType: (body.sftp_auth_type as any) ?? existing.sftpAuthType,
      }).where(eq(destinations.id, id));

      return { id };
    },
    {
      params: t.Object({ id: t.String() }),
      body: t.Object({
        name: t.Optional(t.String()),
        enabled: t.Optional(t.Boolean()),
        host_or_endpoint: t.Optional(t.String()),
        port: t.Optional(t.Number()),
        bucket_or_path: t.Optional(t.String()),
        access_key_or_user: t.Optional(t.String()),
        secret_name: t.Optional(t.String()),
        region: t.Optional(t.String()),
        path_prefix: t.Optional(t.String()),
        sftp_auth_type: t.Optional(t.String()),
      }),
      detail: { summary: "Update destination", tags: ["Destinations"] },
    }
  )

  // -------------------------------------------------------------------------
  // DELETE /destinations/:id — soft archive
  // -------------------------------------------------------------------------
  .delete(
    "/:id",
    async ({ params, set }) => {
      const id = parseInt(params.id, 10);
      const [existing] = await db.select().from(destinations).where(eq(destinations.id, id));
      if (!existing) { set.status = 404; return { error: "Destination not found" }; }

      await db.update(destinations)
        .set({ archivedAt: new Date().toISOString().replace("T", " ").substring(0, 19) })
        .where(eq(destinations.id, id));

      return { id, archived: true };
    },
    {
      params: t.Object({ id: t.String() }),
      detail: { summary: "Archive (soft-delete) destination", tags: ["Destinations"] },
    }
  );
