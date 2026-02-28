import { Elysia } from "elysia";
import { writeFileSync, existsSync } from "fs";
import { mkdirSync } from "fs";

// The trigger file must live on the shared /backups volume which is mounted
// into BOTH the backup-api container and the backup-agent container.
// Writing to /tmp only reaches the API container's own filesystem — the agent
// would never see it.  /backups is the bind-mounted host directory shared
// between the two containers via the pod volume definition.
const TRIGGER_FILE = "/backups/.backup-trigger";

export const triggerRoutes = new Elysia({ prefix: "/trigger" })
  .post(
    "/",
    async ({ set }) => {
      // Write sentinel file that backup.sh checks on startup
      try {
        // Ensure /backups exists (it should, but be defensive)
        mkdirSync("/backups", { recursive: true });
        writeFileSync(TRIGGER_FILE, new Date().toISOString(), { mode: 0o600 });
      } catch (err) {
        set.status = 500;
        return { error: "Failed to write trigger file", detail: String(err) };
      }

      set.status = 202;
      return {
        accepted: true,
        message:
          "Trigger signal written to shared volume. The backup agent will pick it up on next execution.",
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
