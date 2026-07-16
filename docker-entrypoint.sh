#!/bin/sh
set -euo pipefail

# --- Validation helpers ---
validate_identifier() {
    # Only allow alphanumeric + underscore, must start with letter or underscore
    case "$1" in
        ""|[!a-zA-Z_]*|*[!a-zA-Z0-9_]*) return 1 ;;
    esac
    [ "${#1}" -le 63 ]
}

validate_mem_value() {
    # Must be a number optionally followed by k/M/G/B (case-insensitive)
    case "$1" in
        ""|*[!0-9kKmMgGbB]*) return 1 ;;
    esac
}

# --- Root entrypoint: fix ownership, then re-exec as postgres ---
if [ "$(id -u)" = '0' ]; then
    chown -R 999:999 "$PGDATA"
    chmod 700 "$PGDATA"
    exec su-exec postgres "$0" "$@"
fi

# --- Database initialization (only on first run) ---
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "Initializing database..."
    initdb --pgdata="$PGDATA" --auth=trust --username="$PGUSER"

    # --- Network ---
    echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"
    echo "unix_socket_permissions = '0700'" >> "$PGDATA/postgresql.conf"

    # --- SSL (self-signed for dev; replace with real certs in production) ---
    if [ "${POSTGRES_SSL_ENABLED:-on}" = "on" ]; then
        (
            umask 0177
            openssl req -new -x509 -days 365 -nodes \
                -out "$PGDATA/server.crt" \
                -keyout "$PGDATA/server.key" \
                -subj "/CN=localhost" \
                -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
        )
        chown postgres:postgres "$PGDATA/server.crt" "$PGDATA/server.key"
        echo "ssl = on" >> "$PGDATA/postgresql.conf"
        echo "ssl_cert_file = 'server.crt'" >> "$PGDATA/postgresql.conf"
        echo "ssl_key_file = 'server.key'" >> "$PGDATA/postgresql.conf"
        echo "ssl_prefer_server_ciphers = on" >> "$PGDATA/postgresql.conf"
    fi

    # --- Timeouts & Resource Limits ---
    echo "statement_timeout = 60000" >> "$PGDATA/postgresql.conf"
    echo "idle_in_transaction_session_timeout = 60000" >> "$PGDATA/postgresql.conf"

    # --- TCP Keepalive ---
    echo "tcp_keepalives_idle = 300" >> "$PGDATA/postgresql.conf"
    echo "tcp_keepalives_interval = 60" >> "$PGDATA/postgresql.conf"
    echo "tcp_keepalives_count = 5" >> "$PGDATA/postgresql.conf"

    # --- Memory (validated before use) ---
    if [ -n "${POSTGRES_SHARED_BUFFERS:-}" ]; then
        if validate_mem_value "$POSTGRES_SHARED_BUFFERS"; then
            echo "shared_buffers = '${POSTGRES_SHARED_BUFFERS}'" >> "$PGDATA/postgresql.conf"
        else
            echo "WARNING: invalid POSTGRES_SHARED_BUFFERS value, using default" >&2
        fi
    else
        echo "shared_buffers = '128MB'" >> "$PGDATA/postgresql.conf"
    fi

    if [ -n "${POSTGRES_EFFECTIVE_CACHE_SIZE:-}" ]; then
        if validate_mem_value "$POSTGRES_EFFECTIVE_CACHE_SIZE"; then
            echo "effective_cache_size = '${POSTGRES_EFFECTIVE_CACHE_SIZE}'" >> "$PGDATA/postgresql.conf"
        else
            echo "WARNING: invalid POSTGRES_EFFECTIVE_CACHE_SIZE value, using default" >&2
        fi
    else
        echo "effective_cache_size = '512MB'" >> "$PGDATA/postgresql.conf"
    fi

    if [ -n "${POSTGRES_WORK_MEM:-}" ]; then
        if validate_mem_value "$POSTGRES_WORK_MEM"; then
            echo "work_mem = '${POSTGRES_WORK_MEM}'" >> "$PGDATA/postgresql.conf"
        else
            echo "WARNING: invalid POSTGRES_WORK_MEM value, using default" >&2
        fi
    else
        echo "work_mem = '4MB'" >> "$PGDATA/postgresql.conf"
    fi

    if [ -n "${POSTGRES_MAINTENANCE_WORK_MEM:-}" ]; then
        if validate_mem_value "$POSTGRES_MAINTENANCE_WORK_MEM"; then
            echo "maintenance_work_mem = '${POSTGRES_MAINTENANCE_WORK_MEM}'" >> "$PGDATA/postgresql.conf"
        else
            echo "WARNING: invalid POSTGRES_MAINTENANCE_WORK_MEM value, using default" >&2
        fi
    else
        echo "maintenance_work_mem = '64MB'" >> "$PGDATA/postgresql.conf"
    fi

    # --- Logging ---
    echo "log_connections = on" >> "$PGDATA/postgresql.conf"
    echo "log_disconnections = on" >> "$PGDATA/postgresql.conf"
    echo "log_statement = 'ddl'" >> "$PGDATA/postgresql.conf"
    echo "log_line_prefix = '%m [%p] %u@%d '" >> "$PGDATA/postgresql.conf"

    # Start postgres temporarily to configure administrative user
    pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start

    # Create administrative user if POSTGRES_PASSWORD environment variable is defined
    if [ -n "${POSTGRES_PASSWORD:-}" ]; then
        user="${POSTGRES_USER:-postgres}"
        db="${POSTGRES_DB:-$user}"

        # Validate user and database names to prevent injection
        if ! validate_identifier "$user"; then
            echo "ERROR: POSTGRES_USER '$user' contains invalid characters. Only [a-zA-Z0-9_] allowed, max 63 chars." >&2
            pg_ctl -D "$PGDATA" -m fast -w stop
            exit 1
        fi
        if ! validate_identifier "$db"; then
            echo "ERROR: POSTGRES_DB '$db' contains invalid characters. Only [a-zA-Z0-9_] allowed, max 63 chars." >&2
            pg_ctl -D "$PGDATA" -m fast -w stop
            exit 1
        fi

        # Escape password for SQL — only single quotes need escaping
        escaped_pw=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")
        sql_file=$(mktemp)

        if [ "$user" != 'postgres' ]; then
            printf 'CREATE USER "%s" WITH SUPERUSER PASSWORD %s;\n' "$user" "'$escaped_pw'" > "$sql_file"
        else
            printf 'ALTER USER postgres WITH PASSWORD %s;\n' "'$escaped_pw'" > "$sql_file"
        fi

        psql --username=postgres -f "$sql_file"

        if [ "$db" != 'postgres' ]; then
            printf 'CREATE DATABASE "%s" OWNER "%s";\n' "$db" "$user" > "$sql_file"
            psql --username=postgres -f "$sql_file"
        fi

        rm -f "$sql_file"
    fi

    # Shutdown temporary instance
    pg_ctl -D "$PGDATA" -m fast -w stop

    # Replace all trust auth with scram-sha-256 now that password is set
    if grep -q '^local.*trust' "$PGDATA/pg_hba.conf" || grep -q '^host.*trust' "$PGDATA/pg_hba.conf"; then
        sed -i.bak '/^local\|^host/{s/trust *$/scram-sha-256/}' "$PGDATA/pg_hba.conf"
        rm -f "$PGDATA/pg_hba.conf.bak"
    fi

    # Allow password-authenticated connections from any IP
    if [ "${POSTGRES_SSL_ENABLED:-on}" = "on" ]; then
        echo "hostssl all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
    else
        echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
    fi

    echo "Database initialization complete."
fi

# Execute postgres
exec postgres "$@"
