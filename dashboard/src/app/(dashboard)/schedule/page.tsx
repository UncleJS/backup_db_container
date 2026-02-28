import { apiGet } from "@/lib/api-client";
import { formatTs } from "@/lib/utils";
import { ScheduleEditor } from "@/components/ScheduleEditor";

interface ScheduleConfig {
  cron_expression: string;
  enabled: boolean;
  backup_mode: string;
  last_modified_at: string | null;
  modified_by: string | null;
}

function cronDescription(expr: string): string {
  const PRESETS: Record<string, string> = {
    "0 2 * * *": "Every day at 02:00",
    "0 3 * * *": "Every day at 03:00",
    "0 0 * * *": "Every day at midnight",
    "0 2 * * 0": "Every Sunday at 02:00",
    "0 2 1 * *": "1st of every month at 02:00",
    "@daily":    "Every day at midnight",
    "@weekly":   "Every Sunday at midnight",
  };
  return PRESETS[expr] ?? expr;
}

export default async function SchedulePage() {
  let schedule: ScheduleConfig | null = null;
  let error: string | null = null;

  try {
    schedule = await apiGet<ScheduleConfig>("/schedule");
  } catch (err) {
    error = String(err);
  }

  return (
    <div className="space-y-6 max-w-2xl">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Schedule</h1>
        <p className="text-sm text-muted-foreground mt-0.5">Configure when automatic backups run</p>
      </div>

      {error && (
        <div className="bg-destructive/10 border border-destructive/30 rounded-lg p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      {schedule && (
        <>
          {/* Current status card */}
          <div className="bg-card border border-border rounded-lg p-5 space-y-4">
            <div className="flex items-center justify-between">
              <h2 className="text-sm font-semibold text-foreground">Current Schedule</h2>
              <span className={`inline-flex items-center gap-1.5 text-xs font-medium px-2 py-1 rounded-full border
                ${schedule.enabled
                  ? "bg-emerald-400/10 text-emerald-400 border-emerald-400/30"
                  : "bg-muted text-muted-foreground border-border"}`}>
                <span className={`w-1.5 h-1.5 rounded-full ${schedule.enabled ? "bg-emerald-400" : "bg-muted-foreground"}`} />
                {schedule.enabled ? "Active" : "Disabled"}
              </span>
            </div>

            <div className="grid grid-cols-2 gap-4 text-sm">
              <div>
                <p className="text-xs text-muted-foreground mb-1">Cron Expression</p>
                <p className="font-mono text-foreground">{schedule.cron_expression}</p>
                <p className="text-xs text-muted-foreground mt-0.5">{cronDescription(schedule.cron_expression)}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground mb-1">Backup Mode</p>
                <span className="text-xs px-2 py-0.5 rounded bg-muted text-muted-foreground capitalize">
                  {schedule.backup_mode}
                </span>
              </div>
              <div>
                <p className="text-xs text-muted-foreground mb-1">Last Modified</p>
                <p className="text-foreground">{formatTs(schedule.last_modified_at)}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground mb-1">Modified By</p>
                <p className="text-foreground">{schedule.modified_by ?? "—"}</p>
              </div>
            </div>
          </div>

          {/* Schedule editor */}
          <ScheduleEditor current={schedule} />

          {/* Timer note */}
          <div className="bg-yellow-400/5 border border-yellow-400/20 rounded-lg p-4 text-sm text-yellow-400/90">
            <p className="font-medium mb-1">⚠ Applying schedule changes to the system timer</p>
            <p className="text-xs text-muted-foreground">
              Changes saved here update the tracking database. To apply them to the systemd timer,
              run <code className="font-mono bg-muted px-1 rounded">./scripts/apply-schedule.sh</code> on
              the host, or re-run <code className="font-mono bg-muted px-1 rounded">systemctl --user daemon-reload</code> after
              editing <code className="font-mono bg-muted px-1 rounded">backup-agent.timer</code>.
              See the User Guide for full details.
            </p>
          </div>
        </>
      )}
    </div>
  );
}
