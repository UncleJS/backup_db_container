"use client";

import { useState, useTransition } from "react";

type DestType = "s3" | "sftp";

interface FormState {
  name: string;
  type: DestType;
  enabled: boolean;
  host_or_endpoint: string;
  port: string;
  bucket_or_path: string;
  access_key_or_user: string;
  secret_name: string;
  region: string;
  path_prefix: string;
  sftp_auth_type: "password" | "key";
}

const EMPTY: FormState = {
  name: "",
  type: "s3",
  enabled: true,
  host_or_endpoint: "",
  port: "",
  bucket_or_path: "",
  access_key_or_user: "",
  secret_name: "",
  region: "",
  path_prefix: "",
  sftp_auth_type: "password",
};

function Field({
  label,
  children,
  hint,
}: {
  label: string;
  children: React.ReactNode;
  hint?: string;
}) {
  return (
    <div>
      <label className="block text-sm font-medium text-foreground mb-1.5">{label}</label>
      {children}
      {hint && <p className="text-xs text-muted-foreground mt-1">{hint}</p>}
    </div>
  );
}

const inputCls =
  "w-full px-3 py-2 rounded-md border border-input bg-background text-foreground text-sm " +
  "placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring";

export function DestinationForm({ onAdded }: { onAdded?: () => void }) {
  const [form, setForm] = useState<FormState>(EMPTY);
  const [isPending, startTransition] = useTransition();
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function update(key: keyof FormState, value: string | boolean) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSaved(false);

    startTransition(async () => {
      try {
        const payload: Record<string, unknown> = {
          name: form.name.trim(),
          type: form.type,
          enabled: form.enabled,
          host_or_endpoint: form.host_or_endpoint.trim() || undefined,
          bucket_or_path: form.bucket_or_path.trim() || undefined,
          access_key_or_user: form.access_key_or_user.trim() || undefined,
          secret_name: form.secret_name.trim() || undefined,
          path_prefix: form.path_prefix.trim() || undefined,
        };

        if (form.port.trim()) payload.port = parseInt(form.port, 10);

        if (form.type === "s3") {
          payload.region = form.region.trim() || undefined;
        } else {
          payload.sftp_auth_type = form.sftp_auth_type;
        }

        const res = await fetch("/api/destinations", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });

        if (!res.ok) {
          const text = await res.text();
          throw new Error(text || `HTTP ${res.status}`);
        }

        setSaved(true);
        setForm(EMPTY);
        setTimeout(() => setSaved(false), 4000);
        onAdded?.();
      } catch (err) {
        setError(String(err));
      }
    });
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-5">
      {/* Type selector */}
      <div className="flex gap-3">
        {(["s3", "sftp"] as const).map((t) => (
          <label
            key={t}
            className={`flex items-center gap-2 px-4 py-2 rounded-md border cursor-pointer text-sm font-medium transition-colors
              ${form.type === t
                ? "border-primary bg-primary/10 text-primary"
                : "border-border bg-background text-muted-foreground hover:text-foreground"}`}
          >
            <input
              type="radio"
              name="dest_type"
              value={t}
              checked={form.type === t}
              onChange={() => update("type", t)}
              className="sr-only"
            />
            {t === "s3" ? "S3 / S3-compatible" : "SFTP"}
          </label>
        ))}
      </div>

      {/* Common fields */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Field label="Name *">
          <input
            required
            type="text"
            value={form.name}
            onChange={(e) => update("name", e.target.value)}
            placeholder="e.g. My S3 Bucket"
            className={inputCls}
          />
        </Field>

        <Field label={form.type === "s3" ? "Endpoint URL" : "Host"} hint={form.type === "s3" ? "Leave blank for AWS. For MinIO: https://minio.example.com" : undefined}>
          <input
            type="text"
            value={form.host_or_endpoint}
            onChange={(e) => update("host_or_endpoint", e.target.value)}
            placeholder={form.type === "s3" ? "https://s3.amazonaws.com" : "sftp.example.com"}
            className={inputCls}
          />
        </Field>

        <Field label={form.type === "s3" ? "Bucket" : "Remote Path"}>
          <input
            type="text"
            value={form.bucket_or_path}
            onChange={(e) => update("bucket_or_path", e.target.value)}
            placeholder={form.type === "s3" ? "my-backups-bucket" : "/backups"}
            className={inputCls}
          />
        </Field>

        <Field label="Path Prefix" hint="Optional subfolder within bucket/path">
          <input
            type="text"
            value={form.path_prefix}
            onChange={(e) => update("path_prefix", e.target.value)}
            placeholder="prod/db/"
            className={inputCls}
          />
        </Field>

        <Field label={form.type === "s3" ? "Access Key" : "Username"}>
          <input
            type="text"
            value={form.access_key_or_user}
            onChange={(e) => update("access_key_or_user", e.target.value)}
            placeholder={form.type === "s3" ? "AKIAIOSFODNN7EXAMPLE" : "backup-user"}
            className={inputCls}
          />
        </Field>

        <Field
          label="Secret Name"
          hint={`Podman secret name — e.g. "${form.type === "s3" ? "s3_secret_key" : "sftp_password"}"`}
        >
          <input
            type="text"
            value={form.secret_name}
            onChange={(e) => update("secret_name", e.target.value)}
            placeholder={form.type === "s3" ? "s3_secret_key" : "sftp_password"}
            className={inputCls}
          />
        </Field>

        {/* S3-only: region */}
        {form.type === "s3" && (
          <Field label="Region">
            <input
              type="text"
              value={form.region}
              onChange={(e) => update("region", e.target.value)}
              placeholder="us-east-1"
              className={inputCls}
            />
          </Field>
        )}

        {/* SFTP-only: port + auth type */}
        {form.type === "sftp" && (
          <Field label="Port" hint="Default: 22">
            <input
              type="number"
              value={form.port}
              onChange={(e) => update("port", e.target.value)}
              placeholder="22"
              min={1}
              max={65535}
              className={inputCls}
            />
          </Field>
        )}
      </div>

      {/* SFTP auth type */}
      {form.type === "sftp" && (
        <Field label="Auth Type">
          <div className="flex gap-4 mt-1">
            {(["password", "key"] as const).map((a) => (
              <label key={a} className="flex items-center gap-2 cursor-pointer text-sm text-foreground">
                <input
                  type="radio"
                  name="sftp_auth"
                  value={a}
                  checked={form.sftp_auth_type === a}
                  onChange={() => update("sftp_auth_type", a)}
                  className="accent-primary"
                />
                {a === "password" ? "Password" : "SSH Private Key"}
              </label>
            ))}
          </div>
          <p className="text-xs text-muted-foreground mt-1">
            {form.sftp_auth_type === "key"
              ? "Expects Podman secret sftp_private_key (PEM content)"
              : "Expects Podman secret sftp_password"}
          </p>
        </Field>
      )}

      {/* Enabled toggle */}
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-foreground">Enable this destination</p>
          <p className="text-xs text-muted-foreground mt-0.5">Disabled destinations are skipped during uploads</p>
        </div>
        <button
          type="button"
          onClick={() => update("enabled", !form.enabled)}
          className={`relative w-11 h-6 rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-ring
            ${form.enabled ? "bg-primary" : "bg-muted"}`}
        >
          <span
            className={`absolute top-0.5 left-0.5 w-5 h-5 rounded-full bg-white shadow transition-transform
            ${form.enabled ? "translate-x-5" : "translate-x-0"}`}
          />
        </button>
      </div>

      {/* Submit row */}
      <div className="flex items-center gap-3 pt-1">
        <button
          type="submit"
          disabled={isPending}
          className="px-4 py-2 rounded-md bg-primary text-primary-foreground text-sm font-medium
                     hover:bg-primary/90 disabled:opacity-60 transition-colors focus:outline-none focus:ring-2 focus:ring-ring"
        >
          {isPending ? "Adding…" : "Add Destination"}
        </button>
        {saved && <span className="text-sm text-emerald-400">✓ Destination added</span>}
        {error && <span className="text-sm text-destructive">{error}</span>}
      </div>
    </form>
  );
}
