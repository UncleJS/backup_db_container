import { apiGet } from "@/lib/api-client";
import { formatTs, formatBytes, formatDuration } from "@/lib/utils";
import { SizeChart } from "@/components/SizeChart";
import { DurationChart } from "@/components/DurationChart";
import { TriggerButton } from "@/components/TriggerButton";

interface Stats {
  total_runs: number;
  success_rate_30d: number;
  total_size_bytes: number;
  total_files: number;
  upload_success_rate: number;
  last_run: {
    id: number;
    status: string;
    startedAt: string;
    totalSizeBytes: number;
    durationSeconds: number;
  } | null;
  size_history: { date: string; totalSizeBytes: number; runCount: number }[];
  duration_history: { date: string; avgDurationSeconds: number; maxDurationSeconds: number }[];
}

function StatCard({
  label,
  value,
  sub,
  color = "blue",
}: {
  label: string;
  value: string | number;
  sub?: string;
  color?: "blue" | "green" | "yellow" | "red" | "purple";
}) {
  const colors = {
    blue: "text-blue-400 bg-blue-400/10",
    green: "text-emerald-400 bg-emerald-400/10",
    yellow: "text-yellow-400 bg-yellow-400/10",
    red: "text-red-400 bg-red-400/10",
    purple: "text-purple-400 bg-purple-400/10",
  };
  return (
    <div className="bg-card border border-border rounded-lg p-5">
      <p className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-3">{label}</p>
      <p className={`text-2xl font-bold ${colors[color].split(" ")[0]}`}>{value}</p>
      {sub && <p className="text-xs text-muted-foreground mt-1">{sub}</p>}
    </div>
  );
}

function StatusBadge({ status }: { status: string }) {
  const styles: Record<string, string> = {
    success: "bg-emerald-400/15 text-emerald-400 border-emerald-400/30",
    failed: "bg-red-400/15 text-red-400 border-red-400/30",
    partial: "bg-yellow-400/15 text-yellow-400 border-yellow-400/30",
    running: "bg-blue-400/15 text-blue-400 border-blue-400/30",
  };
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium border ${styles[status] ?? "bg-muted text-muted-foreground border-border"}`}>
      {status}
    </span>
  );
}

export default async function OverviewPage() {
  let stats: Stats | null = null;
  let error: string | null = null;

  try {
    stats = await apiGet<Stats>("/stats");
  } catch (err) {
    error = String(err);
  }

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">Overview</h1>
          <p className="text-sm text-muted-foreground mt-0.5">Backup system at a glance</p>
        </div>
        <TriggerButton />
      </div>

      {error && (
        <div className="bg-destructive/10 border border-destructive/30 rounded-lg p-4 text-sm text-destructive">
          Failed to load stats: {error}
        </div>
      )}

      {stats && (
        <>
          {/* Stat cards */}
          <div className="grid grid-cols-2 lg:grid-cols-4 xl:grid-cols-5 gap-4">
            <StatCard label="Total Runs" value={stats.total_runs} color="blue" />
            <StatCard
              label="Success Rate (30d)"
              value={`${stats.success_rate_30d}%`}
              color={stats.success_rate_30d >= 90 ? "green" : stats.success_rate_30d >= 70 ? "yellow" : "red"}
            />
            <StatCard label="Total Backed Up" value={formatBytes(stats.total_size_bytes)} color="purple" />
            <StatCard label="Total Files" value={stats.total_files} color="blue" />
            <StatCard
              label="Upload Success"
              value={`${stats.upload_success_rate}%`}
              color={stats.upload_success_rate >= 90 ? "green" : "yellow"}
            />
          </div>

          {/* Last run card */}
          {stats.last_run && (
            <div className="bg-card border border-border rounded-lg p-5">
              <p className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-3">Last Backup Run</p>
              <div className="flex flex-wrap items-center gap-6">
                <div>
                  <p className="text-xs text-muted-foreground">Status</p>
                  <div className="mt-1"><StatusBadge status={stats.last_run.status} /></div>
                </div>
                <div>
                  <p className="text-xs text-muted-foreground">Started</p>
                  <p className="text-sm font-medium text-foreground mt-0.5">{formatTs(stats.last_run.startedAt)}</p>
                </div>
                <div>
                  <p className="text-xs text-muted-foreground">Size</p>
                  <p className="text-sm font-medium text-foreground mt-0.5">{formatBytes(stats.last_run.totalSizeBytes)}</p>
                </div>
                <div>
                  <p className="text-xs text-muted-foreground">Duration</p>
                  <p className="text-sm font-medium text-foreground mt-0.5">{formatDuration(stats.last_run.durationSeconds)}</p>
                </div>
              </div>
            </div>
          )}

          {/* Charts */}
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <div className="bg-card border border-border rounded-lg p-5">
              <h3 className="text-sm font-semibold text-foreground mb-4">Backup Size (30 days)</h3>
              <SizeChart data={stats.size_history} />
            </div>
            <div className="bg-card border border-border rounded-lg p-5">
              <h3 className="text-sm font-semibold text-foreground mb-4">Backup Duration (30 days)</h3>
              <DurationChart data={stats.duration_history} />
            </div>
          </div>
        </>
      )}
    </div>
  );
}
