"use client";

import { useActionState } from "react";
import { loginAction } from "@/app/actions";

export default function LoginPage() {
  const [state, formAction, isPending] = useActionState(loginAction, null);

  return (
    <div className="min-h-screen flex items-center justify-center bg-background px-4">
      <div className="w-full max-w-sm">
        {/* Logo / title */}
        <div className="mb-8 text-center">
          <div className="inline-flex items-center justify-center w-14 h-14 rounded-xl bg-primary/20 mb-4">
            <svg className="w-7 h-7 text-primary" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2}
                d="M4 7v10c0 2 1 3 3 3h10c2 0 3-1 3-3V7M4 7c0-2 1-3 3-3h10c2 0 3 1 3 3M4 7h16M8 11h8M8 15h5" />
            </svg>
          </div>
          <h1 className="text-2xl font-bold text-foreground">Backup Tool</h1>
          <p className="text-sm text-muted-foreground mt-1">Sign in to your dashboard</p>
        </div>

        {/* Login card */}
        <div className="bg-card border border-border rounded-lg p-6 shadow-xl">
          {/* Error banner */}
          {state?.error && (
            <div className="mb-4 px-3 py-2.5 rounded-md bg-destructive/15 border border-destructive/30 text-destructive text-sm">
              {state.error}
            </div>
          )}

          <form action={formAction} className="space-y-4">
            <div>
              <label htmlFor="username" className="block text-sm font-medium text-foreground mb-1.5">
                Username
              </label>
              <input
                id="username"
                name="username"
                type="text"
                autoComplete="username"
                required
                className="w-full px-3 py-2 rounded-md border border-input bg-background text-foreground
                           placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring
                           text-sm"
                placeholder="admin"
              />
            </div>

            <div>
              <label htmlFor="password" className="block text-sm font-medium text-foreground mb-1.5">
                Password
              </label>
              <input
                id="password"
                name="password"
                type="password"
                autoComplete="current-password"
                required
                className="w-full px-3 py-2 rounded-md border border-input bg-background text-foreground
                           placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring
                           text-sm"
                placeholder="••••••••"
              />
            </div>

            <button
              type="submit"
              disabled={isPending}
              className="w-full py-2.5 px-4 rounded-md bg-primary text-primary-foreground text-sm font-semibold
                         hover:bg-primary/90 focus:outline-none focus:ring-2 focus:ring-ring transition-colors
                         disabled:opacity-60 disabled:cursor-not-allowed"
            >
              {isPending ? "Signing in…" : "Sign in"}
            </button>
          </form>
        </div>

        <p className="text-center text-xs text-muted-foreground mt-6">
          Credentials are configured via Podman secrets
        </p>
      </div>
    </div>
  );
}
