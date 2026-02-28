import { defineConfig } from "drizzle-kit";

const host = process.env.TRACKING_DB_HOST ?? "localhost";
const port = parseInt(process.env.TRACKING_DB_PORT ?? "3307", 10);
const user = process.env.TRACKING_DB_USER ?? "tracking_user";
const database = process.env.TRACKING_DB_NAME ?? "backup_tracking";

// Password read from env (populated from secret at container startup)
const password = process.env.TRACKING_DB_PASSWORD ?? "";

export default defineConfig({
  dialect: "mysql",
  schema: "./src/db/schema.ts",
  out: "./src/db/migrations",
  dbCredentials: {
    host,
    port,
    user,
    password,
    database,
  },
});
