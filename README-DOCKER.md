# Hardened PostgreSQL Server (v17.5)

A maximum-hardened, production-grade PostgreSQL container image built from source on **Alpine Linux 3.24**. Designed with zero-trust principles for secure enterprise environments.

## Highlights & Hardening Features

- **Interactive Shell Access Blocked:** Standard shells are removed. `/bin/sh` is wrapper-managed to block interactive shell invocation (e.g. `docker exec -it sh` returns `Interactive shell access is disabled.`), while preserving script-execution capabilities for PostgreSQL.
- **Immutable Application Binaries:** All PostgreSQL binaries are owned by `0:0` (root) and cannot be modified by the container execution process.
- **Run as Non-Root:** Container execution runs under UID/GID `999` (`postgres` user), with a disabled login shell (`/sbin/nologin`).
- **Minimal Footprint:** No package manager (`apk`) or compilers included in the final stage.
- **Read-Only Root Filesystem Compatible:** Configured to support `read_only: true` container runtime options.
- **SSL/TLS by Default:** Self-signed certificates generated automatically. Disable with `POSTGRES_SSL_ENABLED=off`.
- **Secure Authentication:** Enforces `scram-sha-256` password authentication. `hostssl`-only remote connections.

## Quick Start (Docker Compose)

```yaml
services:
  postgres:
    image: hmtanbir/postgres:latest
    container_name: postgres
    ports:
      - "127.0.0.1:5432:5432"
    env_file:
      - .env
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped

    # --- Security hardening ---
    read_only: true
    tmpfs:
      - /tmp
      - /var/run/postgresql

    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true

    deploy:
      resources:
        limits:
          memory: 1G
          cpus: "2.0"

    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  postgres_data:
    driver: local

```

## Quick Start (Docker CLI)

```bash
docker run -d \
  --name postgres \
  -p 127.0.0.1:5432:5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=your_strong_password_here \
  -e POSTGRES_DB=postgres \
  -v postgres_data:/var/lib/postgresql/data \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /var/run/postgresql \
  --cap-drop=ALL \
  --security-opt no-new-privileges:true \
  --restart unless-stopped \
  hmtanbir/postgres:latest
```

## Supported Environment Variables

- `POSTGRES_USER`: Superuser name (defaults to `postgres`).
- `POSTGRES_PASSWORD`: Superuser password (required).
- `POSTGRES_DB`: Default database name (defaults to `POSTGRES_USER`).
- `POSTGRES_SSL_ENABLED`: Enable/disable SSL. Defaults to `on`. Set to `off` to disable.
- `POSTGRES_SHARED_BUFFERS`: PostgreSQL `shared_buffers` (defaults to `128MB`).
- `POSTGRES_EFFECTIVE_CACHE_SIZE`: PostgreSQL `effective_cache_size` (defaults to `512MB`).
- `POSTGRES_WORK_MEM`: PostgreSQL `work_mem` (defaults to `4MB`).
- `POSTGRES_MAINTENANCE_WORK_MEM`: PostgreSQL `maintenance_work_mem` (defaults to `64MB`).
