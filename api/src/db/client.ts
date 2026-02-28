import { drizzle } from "drizzle-orm/mysql2";
import mysql from "mysql2/promise";
import * as schema from "./schema";

// Read password from environment (populated from Podman secret at startup)
const password = process.env.TRACKING_DB_PASSWORD ?? "";

const pool = mysql.createPool({
  host: process.env.TRACKING_DB_HOST ?? "localhost",
  port: parseInt(process.env.TRACKING_DB_PORT ?? "3307", 10),
  // Default matches MARIADB_USER in backup-tracking-db.container and
  // TRACKING_DB_USER in backup-api.container (both set to "backup_api").
  user: process.env.TRACKING_DB_USER ?? "backup_api",
  password,
  database: process.env.TRACKING_DB_NAME ?? "backup_tracking",
  waitForConnections: true,
  connectionLimit: 10,
  supportBigNumbers: true,
  bigNumberStrings: true,
  timezone: "+00:00",
});

export const db = drizzle(pool, { schema, mode: "default" });
export { pool };
