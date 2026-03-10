# Restore Guide

![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC--BY--NC--SA%204.0-lightgrey.svg)
![Docs](https://img.shields.io/badge/docs-restore-1f6feb)
![Recovery](https://img.shields.io/badge/recovery-runbook-2ea043)

## Table of Contents

- [Restoring a MariaDB Physical Backup (mariadb-backup)](#restoring-a-mariadb-physical-backup-mariadb-backup)
- [Restoring a Logical Backup (mariadb-dump)](#restoring-a-logical-backup-mariadb-dump)
- [Restoring a Podman Volume](#restoring-a-podman-volume)
- [Restoring Container / Pod Configs](#restoring-container--pod-configs)
- [Downloading from S3](#downloading-from-s3)
- [Downloading from SFTP](#downloading-from-sftp)

## Restoring a MariaDB Physical Backup (mariadb-backup)

Physical backups are stored as compressed `.qp` files in `/backups/mariadb/TIMESTAMP/`.

```bash
# 1. Locate the backup directory
BACKUP_DIR=/backups/mariadb/2026-02-28_02-00-00

# 2. Prepare the backup (applies redo logs, makes it consistent)
mariadb-backup --prepare --target-dir="${BACKUP_DIR}"

# 3. Stop the target MariaDB instance
systemctl stop mariadb

# 4. Move aside the existing data directory
mv /var/lib/mysql /var/lib/mysql.bak

# 5. Copy back
mariadb-backup --copy-back --target-dir="${BACKUP_DIR}" \
               --datadir=/var/lib/mysql

# 6. Fix permissions
chown -R mysql:mysql /var/lib/mysql

# 7. Start MariaDB
systemctl start mariadb
```

### Incremental restore

For incremental backups, you need the last full backup plus all subsequent
incrementals applied in order:

```bash
# 1. Prepare the base full backup (do NOT use --rollback yet)
mariadb-backup --prepare --apply-log-only --target-dir=/backups/mariadb/FULL_DIR

# 2. Apply each incremental in chronological order
mariadb-backup --prepare --apply-log-only \
  --target-dir=/backups/mariadb/FULL_DIR \
  --incremental-dir=/backups/mariadb/INC_1

mariadb-backup --prepare \
  --target-dir=/backups/mariadb/FULL_DIR \
  --incremental-dir=/backups/mariadb/INC_2   # last incremental: no --apply-log-only

# 3. Copy back (same as full restore steps 3-7 above)
```

[Back to TOC](#table-of-contents)

## Restoring a Logical Backup (mariadb-dump)

Logical backups are gzipped SQL dumps stored as `.sql.gz` files.

```bash
# Restore a single database
zcat /backups/mariadb/dump/my_database_2026-02-28.sql.gz \
  | mariadb -u root -p my_database

# Restore all databases
zcat /backups/mariadb/dump/all_databases_2026-02-28.sql.gz \
  | mariadb -u root -p
```

[Back to TOC](#table-of-contents)

## Restoring a Podman Volume

Volume backups are `.tar.gz` archives containing the volume contents.

```bash
VOLUME_NAME=myapp-data
BACKUP_FILE=/backups/volumes/myapp-data_2026-02-28.tar.gz

# 1. Create a fresh volume (or ensure it exists)
podman volume create "${VOLUME_NAME}"

# 2. Restore into a temporary container
podman run --rm \
  -v "${VOLUME_NAME}:/restore:z" \
  -v "${BACKUP_FILE}:/backup.tar.gz:ro,z" \
  busybox \
  sh -c "cd /restore && tar xzf /backup.tar.gz --strip-components=1"
```

[Back to TOC](#table-of-contents)

## Restoring Container / Pod Configs

Config exports are JSON files (from `podman inspect`) and `.container` / `.pod`
Quadlet unit files, stored in `/backups/configs/TIMESTAMP.tar.gz`.

```bash
# Extract
tar xzf /backups/configs/configs_2026-02-28.tar.gz -C /tmp/config-restore/

# Review inspect JSON
cat /tmp/config-restore/containers/myapp.json

# Restore Quadlet unit files
cp /tmp/config-restore/quadlet/*.container ~/.config/containers/systemd/
cp /tmp/config-restore/quadlet/*.pod       ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start myapp-pod.service
```

[Back to TOC](#table-of-contents)

## Downloading from S3

```bash
# List available backups
rclone ls S3BACKUPTOOL:my-backups-bucket/backups/

# Download a specific backup
rclone copy S3BACKUPTOOL:my-backups-bucket/backups/mariadb/2026-02-28_02-00-00 \
            /restore/mariadb/2026-02-28_02-00-00
```

[Back to TOC](#table-of-contents)

## Downloading from SFTP

```bash
rclone copy SFTPTOOL:/backups/mariadb/2026-02-28_02-00-00 \
            /restore/mariadb/2026-02-28_02-00-00
```

[Back to TOC](#table-of-contents)

---
Licensed under [CC BY-NC-SA 4.0](../LICENSE.md).
