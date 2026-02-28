# backup_db_container

A self-contained, rootless Podman backup solution for MariaDB databases and Podman volumes.
Runs as a single pod with four containers: tracking database, backup agent, REST API, and Next.js dashboard.

## Features

- **Physical backups** via `mariadb-backup` (full + incremental)
- **Logical backups** via `mariadb-dump`
- **Podman volume backups** via Podman socket API
- **Container/pod config exports** (JSON inspect + Quadlet unit files)
- **S3-compatible uploads** via rclone
- **SFTP uploads** via rclone (password or SSH key auth)
- **Tracking database** — every run, file, and upload attempt is recorded
- **Dark-themed dashboard** — overview, runs table, schedule editor, settings, health checks
- **Manual trigger** — run a backup on demand from the dashboard
- **Systemd timer** — schedule backups with full cron expression support
- **Archive-only data model** — records are never hard-deleted

## Quick Start

```bash
# 1. Clone
git clone <repo> backup_db_container
cd backup_db_container

# 2. Create Podman secrets (see secrets/SECRETS.md)
printf 'root_password' | podman secret create tracking_db_root_password -
printf 'api_password'  | podman secret create tracking_db_password -
# ... (see secrets/SECRETS.md for full list)

# 3. Build images
podman build -f Containerfile.agent         -t localhost/backup-agent:latest .
podman build -f api/Containerfile.api       -t localhost/backup-api:latest   api/
podman build -f dashboard/Containerfile.dashboard -t localhost/backup-dashboard:latest dashboard/
podman build -f tracking-db/Containerfile.tracking-db -t localhost/backup-tracking-db:latest tracking-db/

# 4. Install Quadlet units
cp quadlet/*.pod quadlet/*.container quadlet/*.timer \
   ~/.config/containers/systemd/

# Edit backup-agent.container: replace UID 1000 with your UID (id -u)

# 5. Reload systemd and start
systemctl --user daemon-reload
systemctl --user start backup-pod.service

# 6. Open dashboard
xdg-open http://localhost:3000
```

## Documentation

| Doc | Description |
|-----|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, pod topology, data flow |
| [USER_GUIDE.md](USER_GUIDE.md) | Day-to-day usage, dashboard walkthrough |
| [RESTORE.md](RESTORE.md) | How to restore from backup |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common issues and fixes |

## Stack

| Layer | Technology |
|-------|-----------|
| Container runtime | Rootless Podman + Quadlet (systemd) |
| Backup agent | `mariadb:lts` + rclone |
| API | Bun + Elysia + `@elysiajs/openapi` |
| Database | MariaDB + Drizzle ORM |
| Dashboard | Next.js 15 + Tailwind CSS + shadcn/ui |

## Ports

| Port | Service |
|------|---------|
| 3000 | Dashboard |
| 3001 | API (Swagger UI at `/swagger`) |
| 3307 | Tracking DB (host-side, optional) |
