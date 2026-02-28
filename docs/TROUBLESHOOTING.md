# Troubleshooting

## Container / Pod Issues

### Pod fails to start
```bash
systemctl --user status backup-pod.service
journalctl --user -u backup-pod.service -n 50
```
- Check that all Quadlet files are in `~/.config/containers/systemd/`
- Run `systemctl --user daemon-reload` after any file change
- Verify Podman is available: `podman info`

### Tracking DB container exits immediately
```bash
journalctl --user -u backup-tracking-db.service -n 50
```
- Confirm the `tracking_db_root_password` and `tracking_db_password` secrets exist: `podman secret ls`
- Ensure the `tracking-data` named volume exists: `podman volume ls`
- If the volume is corrupted: `podman volume rm tracking-data` and restart (data loss!)

### API container fails to connect to tracking DB
- Confirm `tracking-db` is healthy: `podman healthcheck run tracking-db`
- Check `TRACKING_DB_HOST=localhost` is set (all containers share the pod network)
- Ensure `TRACKING_DB_USER` and `tracking_db_password` secret match the DB credentials

## Backup Agent Issues

### Agent exits without running
```bash
journalctl --user -u backup-agent.service -n 100
```
- Verify `MARIADB_HOST` and `MARIADB_PORT` point to the correct source MariaDB
- Check `mariadb_backup_password` secret: `podman secret inspect mariadb_backup_password`

### mariadb-backup: "Access denied"
- Confirm the backup user has the required grants:
  ```sql
  GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO 'root'@'%';
  -- or use a dedicated backup user
  ```

### Incremental backup falls back to full
- This is expected on the first run, or if the `.last_full_backup` marker is missing
- Check `/backups/mariadb/.last_full_backup` exists and is readable

### Podman socket errors ("cannot connect to Podman socket")
- Confirm the socket path in `backup-agent.container`: `/run/user/1000/podman/podman.sock`
  (replace 1000 with your actual UID: `id -u`)
- Ensure the socket is active: `systemctl --user status podman.socket`
- Enable it if needed: `systemctl --user enable --now podman.socket`

## Upload Issues

### S3 upload fails
- Test rclone manually:
  ```bash
  RCLONE_CONFIG_S3BACKUPTOOL_SECRET_ACCESS_KEY="$(cat /run/secrets/s3_secret_key)" \
    rclone lsd S3BACKUPTOOL:my-backups-bucket
  ```
- Check `RCLONE_CONFIG_S3BACKUPTOOL_ENDPOINT` and `REGION` are correct
- For AWS: use `PROVIDER=AWS` (not `Other`)

### SFTP upload fails
- Test connectivity: `ssh backup-user@sftp.example.com`
- For key auth: confirm `/run/secrets/sftp_private_key` contains valid PEM content
- For password auth: confirm `sftp_password` secret is set

## Dashboard Issues

### Dashboard shows "Unauthorized" or redirects to login immediately
- Clear browser cookies and try again
- Verify `dashboard_session_secret` secret is set: `podman secret inspect dashboard_session_secret`
- Check `SESSION_SECRET` is being exported in `entrypoint.dashboard.sh`

### Dashboard shows API errors on every page
- Confirm the API is running: `curl http://localhost:3001/health`
- Check `INTERNAL_API_SECRET` matches between api and dashboard containers
- Verify `API_INTERNAL_URL=http://localhost:3001` in the dashboard container

### Schedule changes not reflected in systemd timer
- Run `apply-schedule.sh` on the host after saving in the dashboard:
  ```bash
  export INTERNAL_API_SECRET="$(podman secret inspect internal_api_secret ...)"
  ./scripts/apply-schedule.sh
  ```
- Check the timer status: `systemctl --user status backup-agent.timer`

## Viewing All Logs at Once

```bash
journalctl --user -u 'backup-*' -f
```
