FROM alpine:3.22

# Install deps: restic, postgresql client tools, jq, bash, ca-certs
RUN apk add --no-cache \
      restic \
      postgresql16-client \
      jq \
      bash \
      ca-certificates

# Create script location
WORKDIR /app
COPY vaultwarden-backup.sh /usr/local/bin/vaultwarden-backup.sh
RUN chmod +x /usr/local/bin/vaultwarden-backup.sh

ENV DATA_DIR=/data

ENTRYPOINT ["/usr/local/bin/vaultwarden-backup.sh"]
