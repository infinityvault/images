FROM alpine:3.22

# Install deps: restic, postgresql client tools, jq, bash, ca-certs
RUN apk add --no-cache \
      restic \
      postgresql16-client \
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
