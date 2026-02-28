import { apiGet } from "@/lib/api-client";
import { formatTs, formatBytes, formatDuration } from "@/lib/utils";

interface Run {
  id: number;
  triggerType: string;
  status: string;
  backupMode: string;
  startedAt: string;
  completedAt: string | null;
  durationSeconds: number | null;
  totalSizeBytes: number | null;
  errorMessage: string | null;
}

function StatusBadge({ status }: { status: string }) {
  const styles: Record<string, string> = {
    success: "bg-emerald-400/15 text-emerald-400 border-emerald-400/30",
    failed: "bg-red-400/15 text-red-400 border-red-400/30",
    partial: "bg-yellow-400/15 text-yellow-400 border-yellow-400/30",
    running: "bg-blue-400/15 text-blue-400 border-blue-400/30 animate-pulse",
  };
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border ${styles[status] ?? "bg-muted text-muted-foreground border-border"}`}>
      {status}
    </span>
  );
}

export default async function RunsPage({
  searchParams,
}: {
  searchParams: Promise<{ offset?: string; limit?: string }>;
}) {
  const { offset = "0", limit = "50" } = await searchParams;

  let data: { data: Run[]; total: number } = { data: [], total: 0 };
  let error: string | null = null;

  try {
    data = await apiGet<typeof data>(`/runs?limit=${limit}&offset=${offset}`);
  } catch (err) {
    error = String(err);
  }

  const currentOffset = parseInt(offset, 10);
  const currentLimit = parseInt(limit, 10);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Backup Runs</h1>
        <p className="text-sm text-muted-foreground mt-0.5">
          {data.total} total run{data.total !== 1 ? "s" : ""}
        </p>
      </div>

      {error && (
        <div className="bg-destructive/10 border border-destructive/30 rounded-lg p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      <div className="bg-card border border-border rounded-lg overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border">
                {["ID", "Status", "Mode", "Trigger", "Started", "Completed", "Duration", "Size", ""].map((h) => (
                  <th key={h} className="px-4 py-3 text-left text-xs font-medium text-muted-foreground uppercase tracking-wider whitespace-nowrap">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {data.data.length === 0 ? (
                <tr>
                  <td colSpan={9} className="px-4 py-12 text-center text-muted-foreground text-sm">
                    No backup runs found. Trigger your first backup from the Overview page.
                  </td>
                </tr>
              ) : (
                data.data.map((run) => (
                  <tr key={run.id} className="hover:bg-accent/30 transition-colors">
                    <td className="px-4 py-3 font-mono text-xs text-muted-foreground">#{run.id}</td>
                    <td className="px-4 py-3"><StatusBadge status={run.status} /></td>
                    <td className="px-4 py-3">
                      <span className="text-xs px-1.5 py-0.5 rounded bg-muted text-muted-foreground">
                        {run.backupMode}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">{run.triggerType}</td>
                    <td className="px-4 py-3 font-mono text-xs text-foreground whitespace-nowrap">
                      {formatTs(run.startedAt)}
                    </td>
                    <td className="px-4 py-3 font-mono text-xs text-foreground whitespace-nowrap">
                      {formatTs(run.completedAt)}
                    </td>
                    <td className="px-4 py-3 text-foreground whitespace-nowrap">
                      {formatDuration(run.durationSeconds)}
                    </td>
                    <td className="px-4 py-3 text-foreground whitespace-nowrap">
                      {formatBytes(run.totalSizeBytes)}
                    </td>
                    <td className="px-4 py-3">
                      {run.errorMessage && (
                        <span className="text-xs text-destructive truncate max-w-xs block" title={run.errorMessage}>
                          ⚠ {run.errorMessage.substring(0, 40)}…
                        </span>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* Pagination */}
        {data.total > currentLimit && (
          <div className="px-4 py-3 border-t border-border flex items-center justify-between text-sm">
            <span className="text-muted-foreground">
              Showing {currentOffset + 1}–{Math.min(currentOffset + currentLimit, data.total)} of {data.total}
            </span>
            <div className="flex gap-2">
              {currentOffset > 0 && (
                <a
                  href={`/runs?offset=${currentOffset - currentLimit}&limit=${currentLimit}`}
                  className="px-3 py-1.5 rounded border border-border text-foreground hover:bg-accent transition-colors"
                >
                  ← Prev
                </a>
              )}
              {currentOffset + currentLimit < data.total && (
                <a
                  href={`/runs?offset=${currentOffset + currentLimit}&limit=${currentLimit}`}
                  className="px-3 py-1.5 rounded border border-border text-foreground hover:bg-accent transition-colors"
                >
                  Next →
                </a>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
