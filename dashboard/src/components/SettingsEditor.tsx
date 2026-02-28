"use client";

import { useState, useTransition } from "react";

interface Settings {
  retention_days: string;
  backup_mariadb: string;
  backup_volumes: string;
  backup_configs: string;
  podman_volumes: string;
  compression: string;
  [key: string]: string;
}

export function SettingsEditor({ current }: { current: Settings }) {
  const [form, setForm] = useState({ ...current });
  const [isPending, startTransition] = useTransition();
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function update(key: string, value: string) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function handleSave() {
    setError(null);
    setSaved(false);
    startTransition(async () => {
      try {
        const res = await fetch("/api/settings", {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(form),
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
    <div className="space-y-5">
      {/* Retention */}
      <div className="bg-card border border-border rounded-lg p-5 space-y-4">
        <h2 className="text-sm font-semibold text-foreground">Retention</h2>
        <div>
          <label className="block text-sm font-medium text-foreground mb-1.5">
            Retention Days
          </label>
          <div className="flex items-center gap-3">
            <input
              type="number"
              min={1}
              max={365}
              value={form.retention_days}
              onChange={(e) => update("retention_days", e.target.value)}
              className="w-28 px-3 py-2 rounded-md border border-input bg-background text-foreground text-sm
                         focus:outline-none focus:ring-2 focus:ring-ring"
            />
            <span className="text-sm text-muted-foreground">days (local backups older than this will be pruned)</span>
          </div>
        </div>
      </div>

      {/* Backup targets */}
      <div className="bg-card border border-border rounded-lg p-5 space-y-4">
        <h2 className="text-sm font-semibold text-foreground">Backup Targets</h2>

        {[
          { key: "backup_mariadb", label: "MariaDB", desc: "Physical + logical database backup" },
          { key: "backup_volumes", label: "Podman Volumes", desc: "Tar archive of each named volume" },
          { key: "backup_configs", label: "Container Configs", desc: "Pod/container inspect + Quadlet unit files" },
        ].map(({ key, label, desc }) => (
          <div key={key} className="flex items-center justify-between">
            <div>
              <p className="text-sm font-medium text-foreground">{label}</p>
              <p className="text-xs text-muted-foreground">{desc}</p>
            </div>
            <button
              onClick={() => update(key, form[key] === "true" ? "false" : "true")}
              className={`relative w-11 h-6 rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-ring
                ${form[key] === "true" ? "bg-primary" : "bg-muted"}`}
            >
              <span className={`absolute top-0.5 left-0.5 w-5 h-5 rounded-full bg-white shadow transition-transform
                ${form[key] === "true" ? "translate-x-5" : "translate-x-0"}`} />
            </button>
          </div>
        ))}

        {/* Podman volumes filter */}
        <div>
          <label className="block text-sm font-medium text-foreground mb-1.5">
            Specific Volumes to Back Up
          </label>
          <input
            type="text"
            value={form.podman_volumes}
            onChange={(e) => update("podman_volumes", e.target.value)}
            placeholder="vol1,vol2,vol3 (empty = all volumes)"
            className="w-full px-3 py-2 rounded-md border border-input bg-background text-foreground text-sm
                       focus:outline-none focus:ring-2 focus:ring-ring font-mono"
          />
          <p className="text-xs text-muted-foreground mt-1">Comma-separated volume names. Leave empty to back up all volumes.</p>
        </div>
      </div>

      {/* Compression */}
      <div className="bg-card border border-border rounded-lg p-5 space-y-4">
        <h2 className="text-sm font-semibold text-foreground">Compression</h2>
        <div className="flex gap-3">
          {["gzip"].map((c) => (
            <label key={c} className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                name="compression"
                value={c}
                checked={form.compression === c}
                onChange={() => update("compression", c)}
                className="accent-primary"
              />
              <span className="text-sm text-foreground">{c}</span>
            </label>
          ))}
        </div>
      </div>

      {/* Save */}
      <div className="flex items-center gap-3">
        <button
          onClick={handleSave}
          disabled={isPending}
          className="px-4 py-2 rounded-md bg-primary text-primary-foreground text-sm font-medium
                     hover:bg-primary/90 disabled:opacity-60 transition-colors"
        >
          {isPending ? "Saving…" : "Save Settings"}
        </button>
        {saved && <span className="text-sm text-emerald-400">✓ Saved</span>}
        {error && <span className="text-sm text-destructive">{error}</span>}
      </div>
    </div>
  );
}
