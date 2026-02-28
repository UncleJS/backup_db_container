import { apiGet } from "@/lib/api-client";
import { SettingsEditor } from "@/components/SettingsEditor";

interface Settings {
  retention_days: string;
  backup_mariadb: string;
  backup_volumes: string;
  backup_configs: string;
  podman_volumes: string;
  compression: string;
  [key: string]: string;
}

export default async function SettingsPage() {
  let currentSettings: Settings | null = null;
  let error: string | null = null;

  try {
    currentSettings = await apiGet<Settings>("/settings");
  } catch (err) {
    error = String(err);
  }

  return (
    <div className="space-y-6 max-w-2xl">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Settings</h1>
        <p className="text-sm text-muted-foreground mt-0.5">Configure backup targets and retention</p>
      </div>

      {error && (
        <div className="bg-destructive/10 border border-destructive/30 rounded-lg p-4 text-sm text-destructive">
          {error}
        </div>
      )}

      {currentSettings && <SettingsEditor current={currentSettings} />}
    </div>
  );
}
