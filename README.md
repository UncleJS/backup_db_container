# backup_db_container

![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC--BY--NC--SA%204.0-lightgrey.svg)
![Docs](https://img.shields.io/badge/docs-available-1f6feb)
![Podman](https://img.shields.io/badge/runtime-podman-892ca0)

Self-contained, rootless Podman backup platform for MariaDB databases and Podman volumes.

## Table of Contents

- [Project Docs](#project-docs)
- [Repository Layout](#repository-layout)
- [License](#license)

## Project Docs

- Main docs index: [`docs/README.md`](docs/README.md)
- Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- User guide: [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md)
- Restore guide: [`docs/RESTORE.md`](docs/RESTORE.md)
- Troubleshooting: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
- Secrets reference: [`secrets/SECRETS.md`](secrets/SECRETS.md)

[Back to TOC](#table-of-contents)

## Repository Layout

- `api/`: Bun + Elysia REST API and database schema/migrations
- `dashboard/`: Next.js dashboard UI
- `scripts/`: backup, upload, retention, and schedule scripts
- `quadlet/`: Podman Quadlet units (`.pod`, `.container`, `.timer`)
- `docs/`: technical and operational documentation
- `secrets/`: Podman secret setup/reference docs

[Back to TOC](#table-of-contents)

## License

Licensed under Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International.
See [`LICENSE.md`](LICENSE.md).

[Back to TOC](#table-of-contents)

---
Licensed under [CC BY-NC-SA 4.0](LICENSE.md).
