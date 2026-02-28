import { apiGet } from "@/lib/api-client";

interface HealthCheck {
  name: string;
  status: "ok" | "degraded" | "unreachable";
  latency_ms?: number;
  error?: string;
}

interface HealthResponse {
  status: string;
  timestamp: string;
  checks: HealthCheck[];
}

const CHECK_LABELS: Record<string, string> = {
  tracking_db: "Tracking Database",
  s3: "S3 / Object Storage",
  sftp: "SFTP Server",
  source_mariadb: "Source MariaDB",
};

const CHECK_ICONS: Record<string, string> = {
  tracking_db: "M4 7v10c0 2 1 3 3 3h10c2 0 3-1 3-3V7M4 7c0-2 1-3 3-3h10c2 0 3 1 3 3M4 7h16",
  s3: "M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12",
  sftp: "M8 9l3 3-3 3m5 0h3M5 20h14a2 2 0 002-2V6a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z",
  source_mariadb: "M4 7v10c0 2 1 3 3 3h10c2 0 3-1 3-3V7M4 7c0-2 1-3 3-3h10c2 0 3 1 3 3M4 7h16M8 11h8M8 15h5",
};

function StatusDot({ status }: { status: string }) {
  const colors: Record<string, string> = {
    ok: "bg-emerald-400 shadow-emerald-400/50",
    degraded: "bg-yellow-400 shadow-yellow-400/50",
    unreachable: "bg-red-400 shadow-red-400/50",
  };
  return (
    <span className={`inline-block w-3 h-3 rounded-full shadow-md ${colors[status] ?? "bg-muted"}`} />
  );
}

function HealthCard({ check }: { check: HealthCheck }) {
  const borderColor =
    check.status === "ok"
      ? "border-emerald-400/20"
      : check.status === "degraded"
      ? "border-yellow-400/20"
      : "border-red-400/20";

  return (
    <div className={`bg-card border ${borderColor} rounded-lg p-5 flex items-start gap-4`}>
      <div className="mt-0.5">
        <svg className="w-5 h-5 text-muted-foreground" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d={CHECK_ICONS[check.name] ?? ""} />
        </svg>
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <p className="font-medium text-sm text-foreground">
            {CHECK_LABELS[check.name] ?? check.name}
          </p>
          <StatusDot status={check.status} />
        </div>
        <p className="text-xs text-muted-foreground mt-0.5 capitalize">{check.status}</p>
        {check.latency_ms !== undefined && (
          <p className="text-xs text-muted-foreground mt-1">{check.latency_ms}ms latency</p>
        )}
        {check.error && (
          <p className="text-xs text-destructive mt-1 truncate" title={check.error}>
            {check.error}
          </p>
        )}
      </div>
    </div>
  );
}

export default async function HealthPage() {
  let health: HealthResponse | null = null;
  let error: string | null = null;

  try {
    // Health endpoint is public (no auth required)
    const apiBase = process.env.API_INTERNAL_URL ?? "http://localhost:3001";
    const res = await fetch(`${apiBase}/health`, { cache: "no-store" });
    health = await res.json();
  } catch (err) {
    error = String(err);
  }

  const overallOk = health?.status === "ok";

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">Health</h1>
          <p className="text-sm text-muted-foreground mt-0.5">System connectivity status</p>
        </div>
        {health && (
          <div className={`flex items-center gap-2 px-3 py-1.5 rounded-full border text-sm font-medium
            ${overallOk
              ? "bg-emerald-400/10 text-emerald-400 border-emerald-400/30"
              : "bg-red-400/10 text-red-400 border-red-400/30"}`}>
            <StatusDot status={health.status} />
            {overallOk ? "All systems operational" : "Degraded — check below"}
          </div>
        )}
      </div>

      {error && (
        <div className="bg-destructive/10 border border-destructive/30 rounded-lg p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      {health && (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          {health.checks.map((check) => (
            <HealthCard key={check.name} check={check} />
          ))}
        </div>
      )}

      {health && (
        <p className="text-xs text-muted-foreground">
          Checked at {new Date(health.timestamp).toLocaleString()} · Refresh the page to re-check
        </p>
      )}
    </div>
  );
}
