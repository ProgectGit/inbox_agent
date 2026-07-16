# inbox_agent

Isolated n8n stack for the inbox agent.

## Server layout

- Compose project: `inbox-agent`
- n8n container: `inbox-agent-n8n`
- PostgreSQL container: `inbox-agent-postgres`
- Qdrant container: `inbox-agent-qdrant`
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
- `Inbox — Recovery and Monitoring`: a five-minute watchdog that recovers stale
  work, retries analysis/indexing, stops exhausted jobs, and sends alerts.
- `Inbox — Backblaze B2 Original Upload`: an active S3-compatible original-file
  upload workflow that processes pending attachments every minute.

## Object storage

The attachment schema supports S3-compatible storage metadata, upload status,
bucket/object keys, encryption details, and provider-side timestamps. The
production watchdog tracks successfully stored B2 objects and sends a one-time
Telegram warning when usage crosses 7,000,000,000 bytes (7 GB), leaving room
before the 10 GB free-tier limit.

Production uses the private encrypted bucket `inbox-agent-progectxo` through the
n8n S3 credential `Backblaze B2 Inbox Storage`. The workflow stores originals
under user/year/month/attachment paths and records each resulting object key in
PostgreSQL.

All six workflows are published on the production n8n instance. The older
`Inbox Agent — Telegram + Gemini + RAG` workflow is kept as a reference draft
and must remain inactive because a Telegram bot should have only one production
webhook entry point.

### Telegram usage

Send ordinary text, a link, a Telegram voice message, a photo/screenshot, or a
supported document to save it. Gemini transcribes audio, extracts visible text
from images, and reads documents before the normal classification and RAG
pipeline. Archive formats remain intentionally blocked for the MVP.

Plain-text files (`.txt`, `.md`, `.csv`, `.json`, `.xml`) and Word `.docx`
documents are extracted locally inside n8n; `.docx` parsing uses the bundled
`mammoth` package. This avoids sending unsupported Word MIME types to Gemini.
The n8n container therefore enables `mammoth` for Code nodes through
`NODE_FUNCTION_ALLOW_EXTERNAL` and sets `NODE_PATH` to n8n's installed modules.

Use `/save ...` or `/inbox ...` to force capture when a note begins with wording
that resembles a search command.

Search the Second Brain with `/search ...`, `/find ...`, or natural Ukrainian
phrases beginning with `Знайди`, `Покажи`, `Що я знаю`, or `Пошукай`.

Examples:

```text
/save Ідея: додати щотижневий огляд знань
/search Docker Compose
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
