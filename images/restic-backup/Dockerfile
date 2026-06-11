ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

# Build-time selection of DB client packages.
ARG POSTGRES_CLIENT_PKG=postgresql16-client
ARG MYSQL_CLIENT_PKG=mariadb-client

# Install deps: restic, PostgreSQL/MySQL client tools, jq, bash, ca-certs
RUN apk add --no-cache \
      restic \
      ${POSTGRES_CLIENT_PKG} \
      ${MYSQL_CLIENT_PKG} \
      jq \
      bash \
      ca-certificates \
      curl

# Install supercronic
ADD https://github.com/aptible/supercronic/releases/download/v0.2.34/supercronic-linux-amd64 /usr/bin/supercronic
RUN chmod +x /usr/bin/supercronic

# Create script location
WORKDIR /app
COPY restic-backup.sh /usr/local/bin/restic-backup.sh
RUN chmod +x /usr/local/bin/restic-backup.sh

ENTRYPOINT ["/usr/local/bin/restic-backup.sh"]
