FROM postgres:16-alpine

RUN apk add --no-cache rclone

COPY backup.sh /usr/local/bin/inbox-postgres-backup
RUN chmod 0755 /usr/local/bin/inbox-postgres-backup

ENTRYPOINT ["/usr/local/bin/inbox-postgres-backup"]
