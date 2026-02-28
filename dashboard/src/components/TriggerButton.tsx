"use client";

import { useState, useTransition } from "react";

async function triggerBackup(): Promise<{ ok: boolean; message?: string; error?: string }> {
  const res = await fetch("/api/trigger", { method: "POST" });
  const data = await res.json();
  if (!res.ok) return { ok: false, error: data.error ?? "Request failed" };
  return { ok: true, message: data.message };
}

export function TriggerButton() {
  const [isPending, startTransition] = useTransition();
  const [result, setResult] = useState<{ ok: boolean; message?: string; error?: string } | null>(null);

  function handleClick() {
    setResult(null);
    startTransition(async () => {
      const r = await triggerBackup();
      setResult(r);
    });
  }

  return (
    <div className="flex flex-col items-end gap-2">
      <button
        onClick={handleClick}
        disabled={isPending}
        className="flex items-center gap-2 px-4 py-2 rounded-md bg-primary text-primary-foreground
                   text-sm font-medium hover:bg-primary/90 disabled:opacity-60 disabled:cursor-not-allowed
                   transition-colors focus:outline-none focus:ring-2 focus:ring-ring"
      >
        {isPending ? (
          <>
            <svg className="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z" />
            </svg>
            Triggering…
          </>
        ) : (
          <>
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            Run Backup Now
          </>
        )}
      </button>

      {result?.ok && (
        <p className="text-xs text-emerald-400">{result.message ?? "Triggered successfully."}</p>
      )}
      {result && !result.ok && (
        <p className="text-xs text-destructive">{result.error}</p>
      )}
    </div>
  );
}
