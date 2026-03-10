# User Guide

![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC--BY--NC--SA%204.0-lightgrey.svg)
![Docs](https://img.shields.io/badge/docs-user--guide-1f6feb)
![UI](https://img.shields.io/badge/dashboard-next.js-000000)

## Table of Contents

- [Dashboard Pages](#dashboard-pages)
- [Running a Manual Backup](#running-a-manual-backup)
- [Checking the API](#checking-the-api)
- [Updating the Schedule](#updating-the-schedule)
- [Adding a Destination](#adding-a-destination)
- [Viewing Logs](#viewing-logs)

## Dashboard Pages

### Overview (`/`)
- Stat cards: total runs, success rate, total backup size, last run time
- Line chart: backup size over time
- Bar chart: backup duration over time
- **Run Backup Now** button — triggers an immediate backup

### Backup Runs (`/runs`)
- Paginated table of all backup executions
- Status badges: `success` (green), `running` (yellow), `failed` (red)
- Click a row to see individual files (coming soon)

### Schedule (`/schedule`)
- View the current cron schedule and backup mode
- Edit schedule using presets or a custom cron expression
- Toggle automatic backups on/off
- After saving, run `apply-schedule.sh` on the host to activate the systemd timer

### Settings (`/settings`)
- Configure: retention days, backup mode default, source MariaDB connection,
  which backup types to enable (MariaDB physical, logical, volumes, configs),
  S3/SFTP upload toggles

### Destinations (`/destinations`)
- Add S3 or SFTP upload destinations
- Fields: name, endpoint/host, bucket/path, access key, secret name (Podman),
  region (S3), auth type (SFTP), path prefix
- Destinations can be enabled/disabled without deleting them

### Health (`/health`)
- Traffic-light indicators for: API, tracking DB, S3 connectivity, SFTP connectivity, source MariaDB

[Back to TOC](#table-of-contents)

## Running a Manual Backup

1. Open the dashboard at `http://localhost:3000`
2. Click **Run Backup Now** on the Overview page
3. The agent creates a sentinel file `/tmp/backup-trigger`; the backup container
   picks it up and starts immediately
4. Refresh the Runs page to see the new run

[Back to TOC](#table-of-contents)

## Checking the API

Swagger UI is available at: `http://localhost:3001/swagger`
OpenAPI JSON: `http://localhost:3001/openapi.json`

[Back to TOC](#table-of-contents)

## Updating the Schedule

1. Go to `/schedule` in the dashboard
2. Select a preset or enter a custom cron expression
3. Click **Save Schedule**
4. On the host, run:
   ```bash
   INTERNAL_API_SECRET="$(podman secret inspect internal_api_secret --format '{{.SecretData}}')" \
     ./scripts/apply-schedule.sh
   ```
5. The systemd timer is updated automatically

[Back to TOC](#table-of-contents)

## Adding a Destination

1. Go to `/destinations`
2. Select S3 or SFTP
3. Fill in the form (non-secret fields only — the secret key/password must already
   be a Podman secret)
4. Click **Add Destination**
5. The next backup run will upload to the new destination

[Back to TOC](#table-of-contents)

## Viewing Logs

```bash
# All pod containers
journalctl --user -u backup-pod.service -f

# API only
journalctl --user -u backup-api.service -f

# Last backup agent run
journalctl --user -u backup-agent.service
```

[Back to TOC](#table-of-contents)

---
Licensed under [CC BY-NC-SA 4.0](../LICENSE.md).
