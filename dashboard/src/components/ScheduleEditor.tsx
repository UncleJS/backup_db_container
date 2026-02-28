"use client";

import { useState, useTransition } from "react";

interface ScheduleConfig {
  cron_expression: string;
  enabled: boolean;
  backup_mode: string;
}

const CRON_PRESETS = [
  { label: "Daily at 02:00", value: "0 2 * * *" },
  { label: "Daily at 03:00", value: "0 3 * * *" },
  { label: "Daily at midnight", value: "0 0 * * *" },
  { label: "Every 6 hours", value: "0 */6 * * *" },
  { label: "Every 12 hours", value: "0 */12 * * *" },
  { label: "Weekly (Sun 02:00)", value: "0 2 * * 0" },
  { label: "Monthly (1st 02:00)", value: "0 2 1 * *" },
  { label: "Custom…", value: "custom" },
];

export function ScheduleEditor({ current }: { current: ScheduleConfig }) {
  const [cron, setCron] = useState(current.cron_expression);
  const [enabled, setEnabled] = useState(current.enabled);
  const [mode, setMode] = useState(current.backup_mode);
  const [preset, setPreset] = useState<string>(() => {
    const found = CRON_PRESETS.find((p) => p.value === current.cron_expression && p.value !== "custom");
    return found ? found.value : "custom";
  });

  const [isPending, startTransition] = useTransition();
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function handlePreset(v: string) {
    setPreset(v);
    if (v !== "custom") setCron(v);
  }

  function handleSave() {
    setError(null);
    setSaved(false);
    startTransition(async () => {
      try {
        const res = await fetch("/api/schedule", {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ cron_expression: cron, enabled, backup_mode: mode, modified_by: "dashboard" }),
        });
        if (!res.ok) throw new Error(await res.text());
        setSaved(true);
        setTimeout(() => setSaved(false), 3000);
      } catch (err) {
        setError(String(err));
      }
    });
  }

  return (
    <div className="bg-card border border-border rounded-lg p-5 space-y-5">
      <h2 className="text-sm font-semibold text-foreground">Edit Schedule</h2>

      {/* Enable toggle */}
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-foreground">Enable automatic backups</p>
          <p className="text-xs text-muted-foreground mt-0.5">When disabled, only manual runs will execute</p>
        </div>
        <button
          onClick={() => setEnabled(!enabled)}
          className={`relative w-11 h-6 rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-ring
            ${enabled ? "bg-primary" : "bg-muted"}`}
        >
          <span className={`absolute top-0.5 left-0.5 w-5 h-5 rounded-full bg-white shadow transition-transform
            ${enabled ? "translate-x-5" : "translate-x-0"}`} />
        </button>
      </div>

      {/* Cron preset selector */}
      <div>
        <label className="block text-sm font-medium text-foreground mb-1.5">Schedule Preset</label>
        <select
          value={preset}
          onChange={(e) => handlePreset(e.target.value)}
          className="w-full px-3 py-2 rounded-md border border-input bg-background text-foreground text-sm
                     focus:outline-none focus:ring-2 focus:ring-ring"
        >
          {CRON_PRESETS.map((p) => (
            <option key={p.value} value={p.value}>{p.label}</option>
          ))}
        </select>
      </div>

      {/* Manual cron input */}
      <div>
        <label className="block text-sm font-medium text-foreground mb-1.5">
          Cron Expression
          <a href="https://crontab.guru/" target="_blank" rel="noopener noreferrer"
             className="ml-2 text-xs text-primary hover:underline">crontab.guru ↗</a>
        </label>
        <input
          type="text"
          value={cron}
          onChange={(e) => { setCron(e.target.value); setPreset("custom"); }}
          placeholder="0 2 * * *"
          className="w-full px-3 py-2 rounded-md border border-input bg-background text-foreground font-mono text-sm
                     focus:outline-none focus:ring-2 focus:ring-ring"
        />
      </div>

      {/* Backup mode */}
      <div>
        <label className="block text-sm font-medium text-foreground mb-1.5">Backup Mode</label>
        <div className="flex gap-3">
          {["full", "incremental"].map((m) => (
            <label key={m} className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="backup_mode"
                value={m}
                checked={mode === m}
                onChange={() => setMode(m)}
                className="accent-primary"
              />
              <span className="text-sm text-foreground capitalize">{m}</span>
            </label>
          ))}
        </div>
        {mode === "incremental" && (
          <p className="text-xs text-muted-foreground mt-1">
            First run will always be a full backup. Subsequent runs will be incremental.
          </p>
        )}
      </div>

      {/* Save */}
      <div className="flex items-center gap-3">
        <button
          onClick={handleSave}
          disabled={isPending}
          className="px-4 py-2 rounded-md bg-primary text-primary-foreground text-sm font-medium
                     hover:bg-primary/90 disabled:opacity-60 transition-colors"
        >
          {isPending ? "Saving…" : "Save Schedule"}
        </button>
        {saved && <span className="text-sm text-emerald-400">✓ Saved</span>}
        {error && <span className="text-sm text-destructive">{error}</span>}
      </div>
    </div>
  );
}
