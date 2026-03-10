# Podman Secrets Reference

![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC--BY--NC--SA%204.0-lightgrey.svg)
![Docs](https://img.shields.io/badge/docs-secrets-1f6feb)
![Security](https://img.shields.io/badge/security-podman--secrets-b60205)

All credentials are stored as Podman secrets and never written to env files,
image layers, or logs.

## Table of Contents

- [Creating secrets](#creating-secrets)
- [Listing secrets](#listing-secrets)
- [Rotating a secret](#rotating-a-secret)
- [Secret -> Container mapping](#secret---container-mapping)
- [Notes](#notes)

## Creating secrets

```bash
# MariaDB backup user password (used by backup agent to connect to source DB)
printf 'STRONG_PASSWORD_HERE' | podman secret create mariadb_backup_password -

# Tracking DB password (used by API + agent to connect to tracking-db container)
printf 'STRONG_PASSWORD_HERE' | podman secret create tracking_db_password -

# Tracking DB root password (used by the MariaDB container itself on first init)
printf 'STRONG_ROOT_PASSWORD' | podman secret create tracking_db_root_password -

# S3 secret access key
printf 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' | podman secret create s3_secret_key -

# SFTP password (only needed if using password auth)
printf 'SFTP_PASSWORD_HERE' | podman secret create sftp_password -

# SFTP private key — PEM content (only needed if using key auth)
podman secret create sftp_private_key /path/to/id_rsa

# Internal API secret (shared between API and dashboard)
printf "$(openssl rand -hex 32)" | podman secret create internal_api_secret -

# Dashboard session signing secret (JWT cookie)
printf "$(openssl rand -hex 32)" | podman secret create dashboard_session_secret -

# Dashboard admin password (plain text OR bcrypt hash)
# Plain:   printf 'my-admin-password' | podman secret create dashboard_admin_password -
# Bcrypt:  htpasswd -bnBC 12 "" 'my-admin-password' | tr -d ':\n' | podman secret create dashboard_admin_password -
printf 'my-admin-password' | podman secret create dashboard_admin_password -
```

[Back to TOC](#table-of-contents)

## Listing secrets

```bash
podman secret ls
```

[Back to TOC](#table-of-contents)

## Rotating a secret

```bash
# Remove old, create new
podman secret rm internal_api_secret
printf "$(openssl rand -hex 32)" | podman secret create internal_api_secret -

# Restart affected containers
systemctl --user restart backup-api.service backup-dashboard.service
```

[Back to TOC](#table-of-contents)

## Secret → Container mapping

| Secret name                  | Containers that use it                  | Mounted at                                  |
|------------------------------|-----------------------------------------|---------------------------------------------|
| `mariadb_backup_password`    | backup-agent                            | `/run/secrets/mariadb_backup_password`      |
| `tracking_db_password`       | backup-agent, backup-api                | `/run/secrets/tracking_db_password`         |
| `tracking_db_root_password`  | tracking-db                             | `/run/secrets/tracking_db_root_password`    |
| `s3_secret_key`              | backup-agent                            | `/run/secrets/s3_secret_key`                |
| `sftp_password`              | backup-agent                            | `/run/secrets/sftp_password`                |
| `sftp_private_key`           | backup-agent                            | `/run/secrets/sftp_private_key`             |
| `internal_api_secret`        | backup-api, backup-dashboard            | `/run/secrets/internal_api_secret`          |
| `dashboard_session_secret`   | backup-dashboard                        | `/run/secrets/dashboard_session_secret`     |
| `dashboard_admin_password`   | backup-dashboard                        | `/run/secrets/dashboard_admin_password`     |

[Back to TOC](#table-of-contents)

## Notes

- **Never** pass secrets via `Environment=` in Quadlet files.
- The `mariadb:lts` container reads `MARIADB_ROOT_PASSWORD_FILE` at first init only.
  After init the root password is stored inside `/var/lib/mysql` — the secret is
  still needed for container restarts via `MARIADB_ROOT_PASSWORD_FILE`.
- `sftp_password` and `sftp_private_key` are both optional; the backup agent
  auto-detects which to use at runtime.

[Back to TOC](#table-of-contents)

---
Licensed under [CC BY-NC-SA 4.0](../LICENSE.md).
