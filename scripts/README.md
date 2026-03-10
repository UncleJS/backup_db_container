# Scripts Reference

![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC--BY--NC--SA%204.0-lightgrey.svg)
![Shell](https://img.shields.io/badge/language-bash-89e051)
![Docs](https://img.shields.io/badge/docs-scripts-1f6feb)

Operational reference for all scripts in `scripts/`.

## Table of Contents

- [Execution Model](#execution-model)
- [Script Details](#script-details)
- [Shared Environment and Dependencies](#shared-environment-and-dependencies)
- [Failure and Exit Code Behavior](#failure-and-exit-code-behavior)

## Execution Model

- `backup.sh` is the main orchestrator run inside the `backup-agent` container.
- Helper scripts (`backup_mariadb.sh`, `backup_volumes.sh`, `backup_configs.sh`, `upload_s3.sh`, `upload_sftp.sh`, `prune.sh`) are invoked by `backup.sh`.
- `db_record.sh` is a sourced helper library used by multiple scripts for tracking API writes.
- `apply-schedule.sh` is host-side and updates the systemd user timer from the schedule stored in the tracking API.

Go to TOC: [Table of Contents](#table-of-contents)

## Script Details

### `apply-schedule.sh`

Purpose:
- Host-side utility that fetches schedule config from `GET /schedule`, converts cron to systemd `OnCalendar`, writes `~/.config/containers/systemd/backup-agent.timer`, reloads user systemd, and enables/disables the timer.

Run context:
- Must run on the host (not intended for inside container).

Usage:
```bash
./scripts/apply-schedule.sh
./scripts/apply-schedule.sh --dry-run
```

Inputs:
- Positional: optional `--dry-run`
- Env:
- `API_BASE_URL` (default `http://localhost:3001`)
- `INTERNAL_API_SECRET` (required; may also be loaded from `/run/secrets/internal_api_secret`)

Outputs:
- Rewrites `~/.config/containers/systemd/backup-agent.timer`
- Executes `systemctl --user daemon-reload`
- Executes `systemctl --user enable --now backup-agent.timer` or `disable --now`

Notable behavior:
- Supports simple 5-field cron patterns with `*` or single numeric values.
- Complex cron patterns (ranges, lists, step syntax) are warned and simplified.

### `backup.sh`

Purpose:
- Primary run orchestrator for backup lifecycle and status accounting.

Run context:
- Runs inside backup-agent container, generally via systemd timer or manual trigger.

Inputs:
- Env and secrets only.

Key env/secrets consumed:
- Reads secrets from `/run/secrets`: `mariadb_backup_password`, `tracking_db_password`, `s3_secret_key`, `sftp_password`, `internal_api_secret`
- Core env defaults:
- `BACKUP_OUTPUT_DIR` (default `/backups`)
- `MARIADB_HOST` (default `127.0.0.1`)
- `MARIADB_PORT` (default `3306`)
- `MARIADB_USER` (default `backup_user`)
- `MARIADB_BACKUP_MODE` (`full|incremental`, default `full`)
- `BACKUP_MARIADB`, `BACKUP_VOLUMES`, `BACKUP_CONFIGS` (default `true`)
- `PODMAN_VOLUMES` (optional CSV)
- `BACKUP_RETENTION_DAYS` (default `7`)
- `S3_ENABLED`, `SFTP_ENABLED` (default `false`)
- `API_BASE_URL` (default `http://localhost:3001`)
- `TRIGGER_TYPE` (`scheduled|manual`, default `scheduled`)

Flow:
1. Creates run directory timestamp under `BACKUP_OUTPUT_DIR`.
2. Detects manual trigger file `.backup-trigger` and switches trigger mode.
3. Creates run in tracking API via `db_create_run`.
4. Executes enabled stages in order:
- MariaDB backup
- volume backup
- config export backup
- S3 upload
- SFTP upload
- retention pruning
5. Computes total run size.
6. Finalizes run status (`success`, `partial`, `failed`) with summary error message.

Outputs:
- Backup artifacts under a timestamped run directory.
- Tracking records for run/files/uploads/retention events.

Exit behavior:
- Exits non-zero only for `failed` backup stage failures.
- Upload-only failures produce `partial` and exit zero.

### `backup_mariadb.sh`

Purpose:
- Produces MariaDB physical backup (`mariadb-backup`) and logical dump (`mariadb-dump`) for each run.

Usage (called by `backup.sh`):
```bash
./scripts/backup_mariadb.sh \
  <run_dir> <host> <port> <user> <backup_mode> <api_url> <run_id> <api_secret>
```

Inputs:
- Args:
- `run_dir`, `host`, `port`, `user`, `backup_mode`, `api_url`, `run_id`, `api_secret`
- Env:
- `MARIADB_PASSWORD` (required)
- `BACKUP_OUTPUT_DIR` (used for `.last_full_backup` marker, default `/backups`)

Behavior:
- Incremental mode uses `.last_full_backup` marker if valid.
- Falls back to full when marker is missing/stale.
- Compresses physical output into `mariadb-backup-<mode>.tar.gz`.
- Produces `mariadb-dump-all.sql.gz`.
- Records both files via `db_record_file`.

Outputs:
- `mariadb-backup-full.tar.gz` or `mariadb-backup-incremental.tar.gz`
- `mariadb-dump-all.sql.gz`
- Marker update at `${BACKUP_OUTPUT_DIR}/.last_full_backup` for full backups.

### `backup_volumes.sh`

Purpose:
- Backs up Podman named volumes into `tar.gz` archives by reading mount points from Podman API socket.

Usage:
```bash
./scripts/backup_volumes.sh <run_dir> <api_url> <run_id> <api_secret>
```

Inputs:
- Args: `run_dir`, `api_url`, `run_id`, `api_secret`
- Env:
- `PODMAN_VOLUMES` optional CSV filter (empty means all)
- `PODMAN_SOCKET` (default `/run/podman/podman.sock`)

Behavior:
- Queries `/libpod/volumes/json` for available volumes.
- Optionally filters to requested names.
- Archives each volume to `volume-<name>.tar.gz`.
- Records each archive via `db_record_file`.

Outputs:
- One archive per selected volume in run directory.

### `backup_configs.sh`

Purpose:
- Captures restore-oriented container metadata and unit definitions.

Usage:
```bash
./scripts/backup_configs.sh <run_dir> <api_url> <run_id> <api_secret>
```

Inputs:
- Args: `run_dir`, `api_url`, `run_id`, `api_secret`
- Env:
- `PODMAN_SOCKET` (default `/run/podman/podman.sock`)
- `QUADLET_DIRS` colon-separated search roots

Behavior:
- Exports pod and container inspect JSON via Podman API.
- Copies unit files (`.container`, `.pod`, `.volume`, `.network`, `.timer`, `.service`) from configured directories.
- Writes a `manifest.json` metadata file.
- Archives all collected data into `configs.tar.gz`.
- Records archive via `db_record_file`.

Outputs:
- `configs.tar.gz` in run directory.

### `upload_s3.sh`

Purpose:
- Uploads a run directory to S3-compatible storage with rclone and writes per-file upload attempts.

Usage:
```bash
./scripts/upload_s3.sh <run_dir> <run_ts> <api_url> <run_id> <api_secret>
```

Inputs:
- Args: `run_dir`, `run_ts`, `api_url`, `run_id`, `api_secret`
- Env:
- Required: `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`
- Optional: `S3_ENDPOINT` (default `https://s3.amazonaws.com`), `S3_REGION` (default `us-east-1`), `S3_PATH_PREFIX` (default `backups/`)

Behavior:
- Configures rclone from environment (`RCLONE_CONFIG_S3BACKUPTOOL_*`).
- Uses `rclone copy` to `S3BACKUPTOOL:<bucket>/<prefix>/<run_ts>/`.
- Resolves enabled S3 destination ID from API.
- Records one upload attempt per file via `db_record_upload` when destination and file IDs are available.

Outputs:
- Remote object copies in timestamped path.
- `upload_attempts` records for tracked files.

Exit behavior:
- Returns non-zero on upload failure so orchestrator can mark run `partial`.

### `upload_sftp.sh`

Purpose:
- Uploads run directory to SFTP via rclone with key or password auth and records per-file upload attempts.

Usage:
```bash
./scripts/upload_sftp.sh <run_dir> <run_ts> <api_url> <run_id> <api_secret>
```

Inputs:
- Args: `run_dir`, `run_ts`, `api_url`, `run_id`, `api_secret`
- Env:
- Required: `SFTP_HOST`, `SFTP_USER`
- Optional: `SFTP_PORT` (default `22`), `SFTP_REMOTE_PATH` (default `/backups`), `SFTP_AUTH_TYPE` (`auto|key|password`, default `auto`)
- For password mode: `SFTP_PASSWORD`
- For key mode: `/run/secrets/sftp_private_key` secret file

Behavior:
- Configures rclone from environment (`RCLONE_CONFIG_SFTPTOOL_*`).
- Auto-detects auth mode by key secret presence when `SFTP_AUTH_TYPE=auto`.
- Uses `rclone copy` to `sftptool:<remote_path>/<run_ts>/`.
- Resolves enabled SFTP destination ID from API.
- Writes per-file upload attempts via `db_record_upload`.

Outputs:
- Remote SFTP copies in timestamped path.
- `upload_attempts` records for tracked files.

Exit behavior:
- Returns non-zero on upload failure so orchestrator can mark run `partial`.

### `prune.sh`

Purpose:
- Deletes backup run directories older than retention threshold using directory-name timestamps.

Usage:
```bash
./scripts/prune.sh <backup_output_dir> <retention_days> <api_url> <api_secret>
```

Inputs:
- Args: `backup_output_dir`, `retention_days`, `api_url`, `api_secret`

Behavior:
- Computes cutoff epoch from retention days.
- Selects run directories matching `YYYY-MM-DD_HH-MM-SS` format.
- Parses timestamp from directory name (not inode mtime).
- Records retention event per file in each pruned directory via `db_record_retention`.
- Removes stale `.last_full_backup` marker if it points to missing directory.

Outputs:
- Deleted old run directories.
- `retention_events` audit records.

### `db_record.sh`

Purpose:
- Shared API helper library for writing tracking records.

Usage:
```bash
source "${SCRIPT_DIR}/db_record.sh"
```

Provided functions:
- `db_api(method, path, [body])`
- `db_create_run(trigger_type, backup_mode)`
- `db_complete_run(run_id, status, total_size, [error_msg])`
- `db_record_file(run_id, file_path, file_type)`
- `db_record_upload(file_id, destination_id, status, [bytes], [error], started_at)`
- `db_record_retention(file_path, file_size, retention_days)`

Inputs:
- Requires env: `API_BASE_URL`, `INTERNAL_API_SECRET`

Behavior:
- Uses bearer-authenticated HTTP requests to tracking API.
- Encodes strings safely with `jq -Rs .` for JSON payloads.
- Most operations are non-fatal to avoid aborting data backup flow when telemetry writes fail.

Go to TOC: [Table of Contents](#table-of-contents)

## Shared Environment and Dependencies

Environment expected across the script set:
- API/auth: `API_BASE_URL`, `INTERNAL_API_SECRET`
- Backup source: `MARIADB_HOST`, `MARIADB_PORT`, `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_BACKUP_MODE`
- Feature toggles: `BACKUP_MARIADB`, `BACKUP_VOLUMES`, `BACKUP_CONFIGS`, `S3_ENABLED`, `SFTP_ENABLED`
- Destinations:
- S3: `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_REGION`, `S3_PATH_PREFIX`
- SFTP: `SFTP_HOST`, `SFTP_PORT`, `SFTP_USER`, `SFTP_REMOTE_PATH`, `SFTP_AUTH_TYPE`, `SFTP_PASSWORD`
- Runtime: `BACKUP_OUTPUT_DIR`, `BACKUP_RETENTION_DAYS`, `PODMAN_SOCKET`, `PODMAN_VOLUMES`, `QUADLET_DIRS`

Tools required:
- `bash`, `curl`, `jq`, `tar`, `gzip`, `du`, `stat`, `find`
- `mariadb-backup`, `mariadb-dump`
- `rclone`
- Host-only for schedule apply: `systemctl --user`

Go to TOC: [Table of Contents](#table-of-contents)

## Failure and Exit Code Behavior

- `backup.sh` marks final run as:
- `failed` when backup stages fail (MariaDB/volumes/configs).
- `partial` when only uploads fail.
- `success` when all enabled stages succeed.
- `upload_s3.sh` and `upload_sftp.sh` return non-zero when transfer fails.
- `prune.sh` is called with `|| true` by orchestrator so retention problems do not abort a backup run.
- API tracking failures are largely non-fatal by design in `db_record.sh` wrappers.

Go to TOC: [Table of Contents](#table-of-contents)

---
Licensed under Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International. See [`../LICENSE.md`](../LICENSE.md).
