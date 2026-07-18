# inbox_agent

Isolated n8n stack for the inbox agent.

## Server layout

- Compose project: `inbox-agent`
- n8n container: `inbox-agent-n8n`
- PostgreSQL container: `inbox-agent-postgres`
- Qdrant container: `inbox-agent-qdrant`
- YouTube reader container: `inbox-agent-youtube-reader`
- Office document reader container: `inbox-agent-document-reader`
- Server directory: `/opt/inbox-agent-n8n`
- Public n8n endpoint: `https://inbox.mihabot.top`
- Server-local n8n endpoint: `http://127.0.0.1:5679`

## RAG memory

Qdrant provides persistent vector storage on the internal Docker network. In
n8n, configure a Qdrant credential with URL `http://qdrant:6333` and the API key
stored in the server-side `.env` file. Qdrant is not exposed to the public
internet.

The persistent RAG collection is `inbox_memory`, configured for 3072-dimensional
Cosine vectors to match the current n8n `gemini-embedding-001` integration.

AI nodes:

- Chat model: `gemini-3.1-flash-lite`
- Embeddings: `gemini-embedding-001`
- Vector store collection: `inbox_memory`
- Interface: Telegram Trigger and Telegram Send Message

## Production workflows

- `Inbox — Telegram Capture`: the single Telegram entry point and intent router.
- `Inbox — AI Classification`: Gemini classification, summary, taxonomy, tags,
  and indexing job creation.
- `Inbox — Knowledge Indexing`: controlled chunking, PostgreSQL chunk storage,
  Gemini embeddings, and Qdrant indexing.
- `Inbox — Hybrid Knowledge Search`: PostgreSQL lexical search plus Qdrant
  semantic search, with a grounded Gemini answer.
- `Inbox — Recovery and Monitoring`: a one-minute watchdog that recovers stale
  work, retries analysis/indexing, stops exhausted jobs, and sends alerts.
- `Inbox — Backblaze B2 Original Upload`: an active S3-compatible original-file
  upload workflow started immediately for new attachments, with a five-minute
  recovery scan for missed or failed work.
- `Inbox — Telegram Memory Management`: owner-only listing, inspection,
  archiving, clean reindexing, and confirmed deletion across PostgreSQL,
  Qdrant, and B2.
- `Inbox — Automatic Relation Builder`: runs after successful indexing,
  detects hard duplicate/reference signals, asks Gemini to judge semantic
  relations, and maintains the PostgreSQL knowledge graph.

## Object storage

The attachment schema supports S3-compatible storage metadata, upload status,
bucket/object keys, encryption details, and provider-side timestamps. The
production watchdog tracks successfully stored B2 objects and sends a one-time
Telegram warning when usage crosses 7,000,000,000 bytes (7 GB), leaving room
before the 10 GB free-tier limit.

Production uses the private encrypted bucket `inbox-agent-progectxo` through the
n8n S3 credential `Backblaze B2 Inbox Storage`. The workflow stores originals
under user/year/month/attachment paths and records each resulting object key in
PostgreSQL. Every downloaded binary receives a SHA-256 checksum. Repeated files
reuse the first stored B2 object and record `duplicate_of_attachment_id` rather
than uploading another copy. Failed transfers retry up to eight times with
exponential backoff; stale `uploading` rows are recovered after 15 minutes.
Stored attachments record both the object key and a complete `s3://` path.
The watchdog sends a one-time Telegram alert only after all eight upload
attempts have been exhausted.

All eight production workflows are published on the production n8n instance.
`Inbox — Relation Graph Backfill` is an inactive maintenance workflow for
rebuilding relations across historical data. The older
`Inbox Agent — Telegram + Gemini + RAG` workflow is kept as a reference draft
and must remain inactive because a Telegram bot should have only one production
webhook entry point.

## Disk guardrails

Docker rotates every container log at 10 MB and retains three files. n8n prunes
execution history after seven days or 2,000 executions and keeps failed
execution data for diagnosis. Successful maintenance records are retained only
inside those global limits so n8n closes their execution state correctly. B2
upload binaries are execution-scoped and are removed by the same n8n pruning
mechanism; no separate persistent local original-file directory is used. These
limits affect operational history only; they do not delete PostgreSQL
knowledge, Qdrant vectors, or Backblaze originals.

The `disk-monitor` container checks the host filesystem every five minutes and
writes a warning to its rotated Docker log when usage crosses 80%. It sends no
Telegram messages and writes a recovery line after usage falls below the limit.

The current server limits production concurrency to two executions. After a
server migration, increase `N8N_CONCURRENCY_PRODUCTION_LIMIT` in `.env` to match
the available RAM; storage volumes and all guardrail settings remain portable.

## Automated backups

The `postgres-backup` sidecar creates a compressed logical PostgreSQL dump on
startup and every 24 hours, uploads it directly to the private B2 bucket under
`backups/postgresql/`, and removes the temporary local file after a successful
upload. Failed uploads retry every five minutes. Remote dumps older than 30 days
are deleted after a successful upload. Backup failures are written to rotated
Docker logs and intentionally do not send Telegram messages.

The `config-backup` sidecar encrypts `.env`, `.backup.env`, Compose, and the
nginx virtual host with an Age public key before uploading the bundle to
`backups/config/`. Only the matching private recovery key can decrypt credentials
and `N8N_ENCRYPTION_KEY`; that private key must remain off the server.

Recovery helpers live in `scripts/recovery/`:

- `restore-config.sh` decrypts a recovery bundle into a new directory.
- `test-postgres-restore.sh` validates a dump in a disposable PostgreSQL
  container without touching production.
- `restore-postgres.sh` performs an explicitly confirmed production restore.
- `migrate-to-server.sh` installs the recovered config and database on a new
  server, rebuilds the stack, validates nginx, and starts the services.

Qdrant remains rebuildable from PostgreSQL, so a server migration does not
depend on copying its volume.

### Telegram usage

Send ordinary text, a link, a Telegram voice message, a photo/screenshot, or a
supported document to save it. Gemini transcribes audio, extracts visible text
from images, and reads documents before the normal classification and RAG
pipeline. Archive formats remain intentionally blocked for the MVP.

For ordinary HTTP/HTTPS links, the capture workflow downloads the page with a
bounded timeout, removes scripts and layout chrome, extracts the title,
description, and readable text, and stores that content instead of only the
URL. Local, private-network, and cloud-metadata addresses are rejected before
download. JavaScript-only pages may currently fall back to URL metadata.

YouTube links are routed to the private `youtube-reader` service. It uses the
pinned `yt-dlp` release to retrieve video metadata and prefers Ukrainian,
Russian, then English manual or automatically generated captions without
downloading the video. When captions are unavailable, the title, channel,
description, duration, and chapters still enter the classification and RAG
pipeline.

Plain-text files (`.txt`, `.md`, `.csv`, `.json`, `.xml`) are decoded locally
inside n8n. Office files (`.docx`, `.xlsx`, `.pptx`) are routed to the private
`document-reader` service. It extracts Word headings, paragraphs, tables,
headers, footers, footnotes and document properties; Excel sheet names, cells
and formulas; and PowerPoint slide text, tables and speaker notes. Image-only
Office files fall back to Gemini for visual analysis. Extraction is capped at
20 MB per file, 150 MB of uncompressed Office XML, and 120,000 stored
characters.

Use `/save ...` or `/inbox ...` to force capture when a note begins with wording
that resembles a search command.

Manage stored knowledge directly from Telegram:

```text
/memory             show command help
/recent             list the 10 latest records and their short IDs
/review             list records with incomplete or uncertain classification
/show ID             show the structured analysis and attachments
/edit ID ...         correct taxonomy, tags, title, or summary
/related ID          find related records with an explained score
/merge DUPLICATE MAIN request a safe merge into the main record
/archive ID          archive a record without deleting it
/unarchive ID        restore an archived record
/reindex ID          clear stale vectors and rebuild the RAG index
/delete ID           request destructive deletion
/confirm CODE        confirm deletion within 10 minutes
/cancel CODE         cancel a pending deletion
```

`/delete` never acts immediately. A one-time confirmation is stored in
`inbox.pending_actions` and expires after 10 minutes. Once confirmed, the
workflow deletes the record and dependent rows from PostgreSQL, removes its
Qdrant vectors by `inbox_item_id`, and deletes each B2 object only when no other
attachment references the same bucket and object key.

Manual corrections accept English or Ukrainian field names. Separate multiple
assignments with semicolons; tags are comma-separated. Valid taxonomy values
must already exist in the seeded projects, categories, item types, and
priorities. A successful edit records its Telegram origin and timestamp, clears
the old Qdrant vectors, and rebuilds the RAG index automatically.

```text
/edit a1b2c3d4 project=AI Studio; category=DevOps; priority=High; tags=n8n, Docker
/edit a1b2c3d4 проєкт=Second Brain; тип=Research; назва=Оновлена назва
```

`/review` includes failed or unfinished items, missing AI analysis, incomplete
content extraction, and records classified into `Other`. `/related` works even
before durable relation rows exist: it scores shared project, category, type,
tags, and any stored relation, then explains each match in Telegram.

## Knowledge graph and merging

Every completed RAG indexing job starts the relation builder in the background.
SHA-256 checksum matches, identical source URLs, and direct URL references are
treated as hard signals. Gemini reviews the strongest remaining candidates and
may create `similar`, `supports`, `contradicts`, `references`, or `duplicate`
relations with a score and a short Ukrainian explanation. Weak matches based
only on a broad category are discarded.

Merging is always explicit and directional:

```text
/merge DUPLICATE_ID MAIN_ID
/confirm ONE_TIME_CODE
```

The confirmation expires after 10 minutes. A confirmed merge moves attachments,
tags, document rows, memories, and reusable relations to the main item; records
the source in `metadata.merged_sources`; deletes the duplicate PostgreSQL item
and its Qdrant vectors; and reindexes the combined main item. B2 objects are not
deleted during a merge, so deduplicated originals remain available. `/cancel`
works for pending merges as well as pending deletions.

Search the Second Brain with `/search ...`, `/find ...`, or natural Ukrainian
phrases beginning with `Знайди`, `Покажи`, `Що я знаю`, or `Пошукай`. Restrict
search to the content of uploaded files with `/doc ...`, `/docs ...`,
`/docsearch ...`, or a phrase such as `Знайди в документах ...`.

Examples:

```text
/save Ідея: додати щотижневий огляд знань
/search Docker Compose
/docs резервне копіювання PostgreSQL
Знайди в документах згадки про Shopify
Що я знаю про MCP?
Покажи всі матеріали про AI Studio
```

## Application database

Inbox Agent data is isolated from n8n's internal tables in the PostgreSQL
schema named `inbox`. PostgreSQL is the source of truth; Qdrant is a rebuildable
semantic index.

The initial schema includes users, taxonomy dictionaries, raw inbox items,
attachments, processed knowledge items, chunks, tags, relations,
conversations, durable memories, documents, and retryable processing jobs.

Apply migrations after the containers are running:

```bash
./scripts/migrate.sh
```

Owner identity values are supplied through `.env` and are not stored in the
repository. Duplicate Telegram updates and duplicate content hashes are rejected
by partial unique indexes.

## Access through SSH

```bash
ssh -N -L 5679:127.0.0.1:5679 panakea
```

Then open `http://127.0.0.1:5679` locally.

TLS termination and the production webhook URL are configured at
`https://inbox.mihabot.top`.
