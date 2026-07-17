FROM alpine:3.20

COPY monitor.sh /usr/local/bin/inbox-disk-monitor
RUN chmod 0755 /usr/local/bin/inbox-disk-monitor

ENTRYPOINT ["/usr/local/bin/inbox-disk-monitor"]
