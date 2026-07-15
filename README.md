# Hardened PostgreSQL Server

This repository contains a production-ready, maximum-hardened configuration for **PostgreSQL 17.5**. The image is built from source on Alpine Linux, with strict limits on privileges, immutable files, and interactive shell execution disabled.

## Security Hardening Features

1. **Disabled Interactive Shells:**
   - Interactive shells (`/bin/ash`, `/bin/bash`) are replaced by a compiled C wrapper that blocks interactive execution while safely forwarding script invocations.
2. **Immutable Binaries:**
   - PostgreSQL binaries are owned by `0:0` (root) and cannot be modified by the container execution process.
3. **No-Login/No-Privilege System User:**
   - Runs as a dedicated non-root system user `postgres` (UID/GID `999`) with a shell set to `/sbin/nologin`.
4. **Minimal Attack Surface:**
   - Built on `dhi.io/alpine-base:3.24`, which does not contain the `apk` package manager. No compilers or package managers in the final stage.
5. **Dropped Capabilities & Read-Only Filesystem:**
   - Ready to run with a read-only root filesystem (`read_only: true`), with ephemeral writes bound to designated `tmpfs` mounts (`/tmp`, `/var/run/postgresql`).
   - Drops all standard Linux capabilities (`cap_drop: [ALL]`) and restricts privilege escalation (`no-new-privileges:true`).
6. **SSL/TLS by Default:**
   - Self-signed certificates generated at init with SANs for `localhost` and `127.0.0.1`. Disable with `POSTGRES_SSL_ENABLED=off`.
7. **Secure Password Handling:**
   - Passwords are passed via temporary SQL files, not shell interpolation, preventing SQL injection.
8. **Connection Security:**
   - `pg_hba.conf` enforces `scram-sha-256` authentication and `hostssl`-only remote connections.

---

## Local Development

### Prerequisites
- Docker & Docker Compose

### Running locally
1. Create a `.env` file in the root directory (make sure not to commit this file):
   ```env
   POSTGRES_USER=postgres
   POSTGRES_PASSWORD=CHANGE_ME_USE_STRONG_PASSWORD
   POSTGRES_DB=postgres
   POSTGRES_SSL_ENABLED=on

   # Source verification
   PG_SHA256=9b4f86dd2ac00b914582e9893d1bad1f54bc9be7108fa794318b8184f921ec08
   ```

2. Spin up the container:
   ```bash
   docker compose up -d --build
   ```

3. Connect:
   ```bash
   psql -h 127.0.0.1 -U postgres -d postgres
   ```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | `postgres` | Superuser name |
| `POSTGRES_PASSWORD` | *(required)* | Superuser password |
| `POSTGRES_DB` | Same as `POSTGRES_USER` | Default database name |
| `POSTGRES_SSL_ENABLED` | `on` | Set to `off` to disable SSL |
| `POSTGRES_SHARED_BUFFERS` | `128MB` | PostgreSQL shared_buffers |
| `POSTGRES_EFFECTIVE_CACHE_SIZE` | `512MB` | PostgreSQL effective_cache_size |
| `POSTGRES_WORK_MEM` | `4MB` | PostgreSQL work_mem |
| `POSTGRES_MAINTENANCE_WORK_MEM` | `64MB` | PostgreSQL maintenance_work_mem |

---

## CI/CD Pipeline

The GitHub Actions workflow in `.github/workflows/deploy.yml` triggers on pushes to the `main` branch:
1. Builds the multi-platform Docker image (`linux/amd64` and `linux/arm64`).
2. Pushes the built image to Docker Hub.
3. Automatically updates the Docker Hub repository overview description using `README-DOCKER.md`.
