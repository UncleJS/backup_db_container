import { Elysia, t } from "elysia";
import { db } from "../db/client";
import { backupRuns, backupFiles, uploadAttempts, retentionEvents } from "../db/schema";
import { sql, isNull, eq } from "drizzle-orm";

export const statsRoutes = new Elysia({ prefix: "/stats" })
  .get(
    "/",
    async () => {
      // Total runs
      const [{ totalRuns }] = await db
        .select({ totalRuns: sql<number>`count(*)` })
        .from(backupRuns)
        .where(isNull(backupRuns.archivedAt));

      // Success rate (last 30 days)
      const [successStats] = await db
        .select({
          total: sql<number>`count(*)`,
          succeeded: sql<number>`sum(case when status = 'success' then 1 else 0 end)`,
        })
        .from(backupRuns)
        .where(
          sql`archived_at IS NULL AND started_at >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 30 DAY)`
        );

      const successRate =
        successStats.total > 0
          ? Math.round((successStats.succeeded / successStats.total) * 100)
          : 0;

      // Last run
      const [lastRun] = await db
        .select({
          id: backupRuns.id,
          status: backupRuns.status,
          startedAt: backupRuns.startedAt,
          totalSizeBytes: backupRuns.totalSizeBytes,
          durationSeconds: backupRuns.durationSeconds,
        })
        .from(backupRuns)
        .where(sql`archived_at IS NULL AND status != 'running'`)
        .orderBy(sql`started_at DESC`)
        .limit(1);

      // Total backed-up size (all time)
      const [{ totalSize }] = await db
        .select({ totalSize: sql<number>`coalesce(sum(total_size_bytes), 0)` })
        .from(backupRuns)
        .where(sql`archived_at IS NULL AND status = 'success'`);

      // Total files produced
      const [{ totalFiles }] = await db
        .select({ totalFiles: sql<number>`count(*)` })
        .from(backupFiles)
        .where(isNull(backupFiles.archivedAt));

      // Backup size over last 30 days (for charts)
      const sizeHistory = await db
        .select({
          date: sql<string>`DATE(started_at)`,
          totalSizeBytes: sql<number>`coalesce(sum(total_size_bytes), 0)`,
          runCount: sql<number>`count(*)`,
        })
        .from(backupRuns)
        .where(
          sql`archived_at IS NULL AND status = 'success' AND started_at >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 30 DAY)`
        )
        .groupBy(sql`DATE(started_at)`)
        .orderBy(sql`DATE(started_at) ASC`);

      // Duration history (last 30 days)
      const durationHistory = await db
        .select({
          date: sql<string>`DATE(started_at)`,
          avgDurationSeconds: sql<number>`avg(duration_seconds)`,
          maxDurationSeconds: sql<number>`max(duration_seconds)`,
        })
        .from(backupRuns)
        .where(
          sql`archived_at IS NULL AND status IN ('success', 'partial') AND duration_seconds IS NOT NULL AND started_at >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 30 DAY)`
        )
        .groupBy(sql`DATE(started_at)`)
        .orderBy(sql`DATE(started_at) ASC`);

      // Upload success rate
      const [uploadStats] = await db
        .select({
          total: sql<number>`count(*)`,
          succeeded: sql<number>`sum(case when status = 'success' then 1 else 0 end)`,
        })
        .from(uploadAttempts)
        .where(isNull(uploadAttempts.archivedAt));

      return {
        total_runs: totalRuns,
        success_rate_30d: successRate,
        total_size_bytes: totalSize,
        total_files: totalFiles,
        last_run: lastRun ?? null,
        upload_success_rate:
          uploadStats.total > 0
            ? Math.round((uploadStats.succeeded / uploadStats.total) * 100)
            : 100,
        size_history: sizeHistory,
        duration_history: durationHistory,
      };
    },
    { detail: { summary: "Get aggregate dashboard stats", tags: ["Stats"] } }
  );
