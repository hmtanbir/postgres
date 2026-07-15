# Stage 1: Compile PostgreSQL on Alpine (musl libc)
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

RUN apk add --no-cache \
    curl ca-certificates tar gcc make musl-dev \
    readline-dev zlib-dev openssl-dev util-linux-dev \
    linux-headers bison flex perl

ARG PG_VERSION=18_4
ARG PG_URL=https://github.com/postgres/postgres/archive/refs/tags/REL_${PG_VERSION}.tar.gz
ARG PG_SHA256

# PG_SHA256 is mandatory — supply via --build-arg to verify download integrity
RUN set -euo pipefail \
    && if [ -z "${PG_SHA256:-}" ]; then echo "ERROR: PG_SHA256 is required. Pass --build-arg PG_SHA256=<hash>" >&2; exit 1; fi \
    && curl -fSL "$PG_URL" -o /tmp/postgres.tar.gz \
    && echo "$PG_SHA256  /tmp/postgres.tar.gz" | sha256sum -c - \
    && mkdir -p /usr/src/postgres \
    && tar -xzf /tmp/postgres.tar.gz -C /usr/src/postgres --strip-components=1 \
    && rm /tmp/postgres.tar.gz \
    && cd /usr/src/postgres \
    && ./configure \
        --prefix=/usr/local \
        --with-openssl \
        --without-icu \
        --with-uuid=e2fs \
    && (make -j "$(nproc)" || make) \
    && make install \
    && rm -rf /usr/local/include /usr/local/lib/*.a /usr/local/lib/pkgconfig

# Stage 2: Prepare shared libraries, shell wrapper, and utilities
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS deps

RUN apk add --no-cache gcc musl-dev su-exec openssl

RUN mkdir -p /staging/usr/local/lib /staging/usr/local/bin /staging/usr/lib /staging/lib /staging/bin /staging/etc/ssl \
    # musl libc
    && cp -d /lib/ld-musl-*.so* /staging/lib/ || true \
    # runtime shared libraries
    && cp -d /usr/lib/libz.so* /usr/lib/libreadline.so* /usr/lib/libncursesw.so* \
            /usr/lib/libcrypto.so* /usr/lib/libssl.so* /staging/usr/lib/ || true \
    # su-exec + openssl + config
    && cp -d /sbin/su-exec /staging/usr/local/bin/ \
    && cp -d /usr/bin/openssl /staging/usr/local/bin/ \
    && cp /etc/ssl/openssl.cnf /staging/etc/ssl/openssl.cnf \
    # Keep busybox available and create real_sh as a wrapper that invokes it as "sh"
    && cp /bin/busybox /staging/bin/busybox \
    && ln -s busybox /staging/bin/real_sh

# Compile shell wrapper that blocks interactive/command-execution shell usage
RUN printf '#include <stdio.h>\n#include <unistd.h>\n#include <string.h>\nint main(int argc, char *argv[]) {\n    if (argc <= 1) {\n        fprintf(stderr, "Interactive shell access is disabled.\\n");\n        return 1;\n    }\n    for (int i = 1; i < argc; i++) {\n        const char *a = argv[i];\n        if (a[0] != 0x2D || a[1] == 0) continue;\n        if (strcmp(a, "-i") == 0 || strcmp(a, "--interactive") == 0 ||\n            strcmp(a, "-s") == 0 || strcmp(a, "--shell") == 0) {\n            fprintf(stderr, "Interactive shell access is disabled.\\n");\n            return 1;\n        }\n        break;\n    }\n    argv[0] = "sh";\n    execv("/bin/busybox", argv);\n    return 1;\n}\n' > /tmp/wrapper.c \
    && gcc -O2 /tmp/wrapper.c -o /staging/bin/sh \
    && cp /staging/bin/sh /staging/bin/ash \
    && rm /tmp/wrapper.c

# Stage 3: Final hardened image
FROM dhi.io/alpine-base:3.24@sha256:037a503be3d6f50f01bde0ef366e9b9c84060a2db5781b076df40cdd706e5119

ARG LABEL_VERSION=18.4
LABEL maintainer="hmtanbir" \
      version="${LABEL_VERSION}" \
      description="Hardened PostgreSQL ${LABEL_VERSION} server with shell access disabled"

USER 0

# Copy shared libraries, shell wrapper, su-exec, openssl from deps
COPY --from=deps /staging/ /
# Use busybox sh for subsequent build steps (wrapper blocks /bin/sh)
SHELL ["/bin/busybox", "sh", "-c"]

# Copy postgres binaries, libraries, and data files from builder
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/share/postgresql/ /usr/local/share/postgresql/

# Copy readline/ncurses from builder's Alpine to match psql's linked version
COPY --from=builder /usr/lib/libreadline.so* /usr/lib/
COPY --from=builder /usr/lib/libncursesw.so* /usr/lib/

# Create postgres user, directories, clean up bash, copy entrypoint
RUN addgroup -g 999 postgres \
    && adduser -u 999 -G postgres -h /var/lib/postgresql -s /sbin/nologin -H -D postgres \
    && rm -f /bin/bash /usr/bin/bash \
    && mkdir -p /var/lib/postgresql/data /var/run/postgresql \
    && chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql \
    && chmod 700 /var/lib/postgresql /var/run/postgresql

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh

ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    PGDATA=/var/lib/postgresql/data \
    PGUSER=postgres

EXPOSE 5432

HEALTHCHECK --interval=120s --timeout=5s --start-period=30s --retries=3 \
    CMD pg_isready -U postgres || exit 1

USER 999
WORKDIR /var/lib/postgresql

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
