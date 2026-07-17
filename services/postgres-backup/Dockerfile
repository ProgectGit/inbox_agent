FROM postgres:16-alpine

RUN apk add --no-cache age rclone

COPY backup.sh /usr/local/bin/inbox-postgres-backup
COPY config-backup.sh /usr/local/bin/inbox-config-backup
RUN chmod 0755 /usr/local/bin/inbox-postgres-backup /usr/local/bin/inbox-config-backup

ENTRYPOINT ["/usr/local/bin/inbox-postgres-backup"]
