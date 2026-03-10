# Architecture

![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC--BY--NC--SA%204.0-lightgrey.svg)
![Docs](https://img.shields.io/badge/docs-architecture-1f6feb)
![Design](https://img.shields.io/badge/design-system-0969da)

## Table of Contents

- [Pod Topology](#pod-topology)
- [Authentication Flow](#authentication-flow)
- [Backup Agent Flow](#backup-agent-flow)
- [Database Schema](#database-schema)
- [Secrets Model](#secrets-model)
- [Scheduling](#scheduling)
- [Data Lifecycle](#data-lifecycle)

## Pod Topology

```
┌─────────────────────────────── backup-pod ─────────────────────────────────┐
│                                                                              │
│  ┌──────────────────┐    ┌──────────────────┐    ┌────────────────────────┐ │
│  │  tracking-db     │    │  backup-api      │    │  backup-dashboard      │ │
│  │  mariadb:lts     │◄───│  oven/bun:1      │◄───│  node:22-alpine        │ │
│  │  :3306 (pod)     │    │  :3001           │    │  :3000                 │ │
│  │  Vol: tracking-  │    │  /swagger        │    │  Next.js App Router    │ │
│  │  data            │    │  Drizzle ORM     │    │  httpOnly cookie auth  │ │
│  └──────────────────┘    └──────────────────┘    └────────────────────────┘ │
│                                    ▲                                          │
│  ┌─────────────────────────────────┘                                         │
│  │  backup-agent                                                              │
│  │  mariadb:lts + rclone                                                      │
│  │  Bind: /backups, /run/podman/podman.sock (RO)                              │
│  │  Runs as: systemd one-shot (timer)                                         │
│  └────────────────────────────────────────────────────────────────────────── │
└──────────────────────────────────────────────────────────────────────────────┘
```

All containers share the pod network (`localhost`). No inter-container DNS is needed.

[Back to TOC](#table-of-contents)

## Authentication Flow

```
Browser → Next.js dashboard
  └─ Login form → loginAction (server action)
       └─ Verifies ADMIN_PASSWORD (bcrypt or plain)
       └─ Creates signed JWT → httpOnly cookie (SESSION_SECRET)

Dashboard (SSR) → Elysia API
  └─ Authorization: Bearer <INTERNAL_API_SECRET>
  └─ API validates secret via withAuth plugin

Dashboard (client components) → Next.js /api/* route handlers
  └─ Route handler checks getSession() cookie
  └─ Forwards to Elysia with Bearer header
```

[Back to TOC](#table-of-contents)

## Backup Agent Flow

```
backup.sh (main)
  ├─ Read all secrets from /run/secrets/*
  ├─ POST /runs → get RUN_ID
  ├─ backup_mariadb.sh  → mariadb-backup (physical) + mariadb-dump (logical)
  │     └─ POST /files  for each .qp / .sql.gz file
  ├─ backup_volumes.sh  → podman API → tar each volume
  │     └─ POST /files  for each .tar.gz
  ├─ backup_configs.sh  → podman inspect JSON + Quadlet unit files
  │     └─ POST /files
  ├─ upload_s3.sh       → rclone sync → POST /uploads
  ├─ upload_sftp.sh     → rclone sync → POST /uploads
  ├─ prune.sh           → find -mtime +N → POST /retention-events
  └─ PATCH /runs/:id    → finalize (status, duration, total_size)
```

[Back to TOC](#table-of-contents)

## Database Schema

| Table | Purpose |
|-------|---------|
| `backup_runs` | One row per backup execution |
| `backup_files` | One row per file created |
| `upload_attempts` | One row per upload to a destination |
| `destinations` | S3/SFTP upload targets (soft-delete) |
| `schedule_config` | Singleton (id=1) cron schedule |
| `settings` | Key-value store for agent config |
| `retention_events` | Log of pruned files |

[Back to TOC](#table-of-contents)

## Secrets Model

All secrets are Podman secrets mounted at `/run/secrets/<name>`. They are read
into environment variables inside each container's entrypoint script and never
written to logs, image layers, or env files. See `secrets/SECRETS.md`.

[Back to TOC](#table-of-contents)

## Scheduling

Two mechanisms are supported:

1. **Quadlet timer** (`backup-agent.timer`) — recommended. Managed by systemd.
   Run `apply-schedule.sh` after updating the schedule via the dashboard.

2. **User crontab** — see `cron/backup-cron.example`.

[Back to TOC](#table-of-contents)

## Data Lifecycle

- No hard deletes in the tracking DB. Destinations use `archived_at` soft-delete.
- Local backup files are pruned by `prune.sh` after `RETENTION_DAYS`.
- All pruning events are recorded in `retention_events`.

[Back to TOC](#table-of-contents)

---
Licensed under [CC BY-NC-SA 4.0](../LICENSE.md).
