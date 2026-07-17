# Inbox Agent recovery and migration

Keep these two files together in secure offline storage:

- `inbox-agent-recovery-key.txt` — the private Age identity; never copy it to
  GitHub or leave it on the production server.
- `inbox-agent-config-latest.tar.gz.age` — the encrypted recovery bundle.

PostgreSQL dumps and newer encrypted config bundles are stored in the private
B2 bucket. The database dump contains both the `inbox` knowledge schema and the
n8n internal database, including workflows and encrypted credentials.

## Verify an existing database dump

The test uses a disposable PostgreSQL container backed by a 512 MB tmpfs. It
does not connect to or modify production.

```bash
./scripts/recovery/test-postgres-restore.sh /path/to/inbox-agent.dump
```

## Decrypt the recovery configuration

Install Age, then run:

```bash
./scripts/recovery/restore-config.sh \
  /path/to/inbox-agent-config-latest.tar.gz.age \
  /path/to/inbox-agent-recovery-key.txt \
  /tmp/restored-inbox-agent-config
```

The output contains `.env`, `.backup.env`, Compose, and the nginx virtual host.
Treat the complete restored directory as secret material and remove it after
migration.

## Migrate to a replacement server

Install Docker with Compose, nginx, Git, and Age. Clone this repository on the
new server and run as root:

```bash
./scripts/recovery/migrate-to-server.sh \
  /tmp/restored-inbox-agent-config
```

The migration script installs the recovered configuration, builds the images,
downloads the newest PostgreSQL dump directly from B2, restores it, starts the
stack, validates nginx, and reloads it. The production restore helper refuses
to drop a database unless the explicit `CONFIRM_RESTORE=n8n_agent` guard is
present.

After DNS points to the new server, verify:

1. `https://inbox.mihabot.top/healthz` returns HTTP 200.
2. Telegram text capture creates an `inbox.inbox_items` row.
3. A file is uploaded to object storage.
4. Hybrid search returns the saved item.
5. Both backup containers become healthy.

Qdrant is a rebuildable index. If its volume is not moved, enqueue PostgreSQL
knowledge items for indexing after the database restore.
