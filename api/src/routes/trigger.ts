import { Elysia } from "elysia";
import { writeFileSync, existsSync } from "fs";
import { db } from "../db/client";
import { sql } from "drizzle-orm";

const TRIGGER_FILE = "/tmp/backup-trigger";

export const triggerRoutes = new Elysia({ prefix: "/trigger" })
  .post(
    "/",
    async ({ set }) => {
      // Write sentinel file that backup.sh checks on startup
      try {
        writeFileSync(TRIGGER_FILE, new Date().toISOString(), { mode: 0o600 });
      } catch (err) {
        set.status = 500;
        return { error: "Failed to write trigger file", detail: String(err) };
      }

      set.status = 202;
      return {
        accepted: true,
        message:
          "Trigger signal written. The backup agent will pick it up on next execution or manual podman run.",
        trigger_file: TRIGGER_FILE,
      };
    },
    { detail: { summary: "Trigger a manual backup run", tags: ["Trigger"] } }
  )

  .get(
    "/status",
    async () => {
      const pending = existsSync(TRIGGER_FILE);
      return { trigger_pending: pending };
    },
    { detail: { summary: "Check if a manual trigger is pending", tags: ["Trigger"] } }
  );
