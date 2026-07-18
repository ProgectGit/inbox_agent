BEGIN;

CREATE TABLE IF NOT EXISTS inbox.digest_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES inbox.users(id) ON DELETE CASCADE,
  digest_type text NOT NULL CHECK (digest_type IN ('weekly')),
  period_start date NOT NULL,
  period_end date NOT NULL,
  delivered_at timestamptz NOT NULL DEFAULT now(),
  metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, digest_type, period_start, period_end)
);

CREATE INDEX IF NOT EXISTS digest_runs_user_period_idx
  ON inbox.digest_runs (user_id, period_end DESC);

CREATE OR REPLACE FUNCTION inbox.execute_knowledge_access_command(
  p_telegram_user_id bigint,
  p_command text,
  p_argument text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = inbox, public
AS $$
DECLARE
  v_user inbox.users%ROWTYPE;
  v_command text := lower(trim(coalesce(p_command, '')));
  v_prefix text := lower(trim(coalesce(p_argument, '')));
  v_target_id uuid;
  v_target_count integer;
  v_knowledge_id uuid;
  v_title text;
  v_items jsonb;
BEGIN
  SELECT * INTO v_user
  FROM inbox.users
  WHERE telegram_user_id = p_telegram_user_id AND status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'unauthorized');
  END IF;

  IF v_command = 'duplicates' THEN
    WITH raw_pairs AS (
      SELECT newer.id AS duplicate_id, older.id AS canonical_id,
        newer.inbox_item_id AS duplicate_inbox_id, older.inbox_item_id AS canonical_inbox_id,
        newer.title AS duplicate_title, older.title AS canonical_title,
        0.99::numeric AS score, 'Однакова SHA-256 контрольна сума файла'::text AS reason,
        newer.created_at
      FROM inbox.knowledge_items newer
      JOIN inbox.knowledge_items older
        ON older.user_id = newer.user_id AND older.created_at < newer.created_at
      WHERE newer.user_id = v_user.id
        AND EXISTS (
          SELECT 1
          FROM inbox.attachments newer_attachment
          JOIN inbox.attachments older_attachment
            ON older_attachment.checksum_sha256 = newer_attachment.checksum_sha256
           AND older_attachment.checksum_sha256 IS NOT NULL
          WHERE newer_attachment.inbox_item_id = newer.inbox_item_id
            AND older_attachment.inbox_item_id = older.inbox_item_id
        )
      UNION ALL
      SELECT newer.id, older.id, newer.inbox_item_id, older.inbox_item_id,
        newer.title, older.title, 0.97::numeric, 'Однаковий URL джерела', newer.created_at
      FROM inbox.knowledge_items newer
      JOIN inbox.knowledge_items older
        ON older.user_id = newer.user_id AND older.created_at < newer.created_at
       AND older.source_url = newer.source_url AND newer.source_url IS NOT NULL
      WHERE newer.user_id = v_user.id
      UNION ALL
      SELECT
        CASE WHEN source.created_at > target.created_at THEN source.id ELSE target.id END,
        CASE WHEN source.created_at > target.created_at THEN target.id ELSE source.id END,
        CASE WHEN source.created_at > target.created_at THEN source.inbox_item_id ELSE target.inbox_item_id END,
        CASE WHEN source.created_at > target.created_at THEN target.inbox_item_id ELSE source.inbox_item_id END,
        CASE WHEN source.created_at > target.created_at THEN source.title ELSE target.title END,
        CASE WHEN source.created_at > target.created_at THEN target.title ELSE source.title END,
        relation.score, coalesce(relation.explanation, 'Relation Builder визначив дубль'),
        greatest(source.created_at, target.created_at)
      FROM inbox.relations relation
      JOIN inbox.knowledge_items source ON source.id = relation.source_item_id
      JOIN inbox.knowledge_items target ON target.id = relation.target_item_id
      WHERE relation.relation_type = 'duplicate' AND source.user_id = v_user.id
    ), deduplicated AS (
      SELECT DISTINCT ON (duplicate_id, canonical_id)
        duplicate_inbox_id, canonical_inbox_id, duplicate_title, canonical_title,
        score, reason, created_at
      FROM raw_pairs
      ORDER BY duplicate_id, canonical_id, score DESC
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'duplicate_short_id', left(duplicate_inbox_id::text, 8),
      'canonical_short_id', left(canonical_inbox_id::text, 8),
      'duplicate_title', duplicate_title,
      'canonical_title', canonical_title,
      'score', score,
      'reason', reason
    ) ORDER BY score DESC, created_at DESC), '[]'::jsonb)
    INTO v_items
    FROM (SELECT * FROM deduplicated ORDER BY score DESC, created_at DESC LIMIT 10) limited;

    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'duplicates', 'items', v_items);
  END IF;

  IF v_command NOT IN ('graph', 'file', 'download') THEN
    RETURN jsonb_build_object('route', 'delegate');
  END IF;

  IF length(v_prefix) < 6 OR v_prefix !~ '^[0-9a-f-]+$' THEN
    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'item_id_required');
  END IF;

  SELECT count(*), (array_agg(item.id))[1]
  INTO v_target_count, v_target_id
  FROM inbox.inbox_items item
  WHERE item.user_id = v_user.id AND item.id::text LIKE v_prefix || '%';

  IF v_target_count = 0 THEN RETURN jsonb_build_object('route', 'curation_direct', 'status', 'item_not_found'); END IF;
  IF v_target_count > 1 THEN RETURN jsonb_build_object('route', 'curation_direct', 'status', 'item_id_ambiguous'); END IF;

  SELECT knowledge.id, knowledge.title INTO v_knowledge_id, v_title
  FROM inbox.knowledge_items knowledge WHERE knowledge.inbox_item_id = v_target_id;

  IF v_knowledge_id IS NULL THEN
    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'knowledge_not_ready');
  END IF;

  IF v_command = 'graph' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'direction', graph_row.direction,
      'relation_type', graph_row.relation_type,
      'score', graph_row.score,
      'other_short_id', left(graph_row.other_inbox_id::text, 8),
      'other_title', graph_row.other_title,
      'explanation', graph_row.explanation
    ) ORDER BY graph_row.score DESC, graph_row.relation_type), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT 'out'::text AS direction, relation.relation_type, relation.score,
        other.inbox_item_id AS other_inbox_id, other.title AS other_title, relation.explanation
      FROM inbox.relations relation
      JOIN inbox.knowledge_items other ON other.id = relation.target_item_id
      WHERE relation.source_item_id = v_knowledge_id
      UNION ALL
      SELECT 'in', relation.relation_type, relation.score,
        other.inbox_item_id, other.title, relation.explanation
      FROM inbox.relations relation
      JOIN inbox.knowledge_items other ON other.id = relation.source_item_id
      WHERE relation.target_item_id = v_knowledge_id
    ) graph_row;

    RETURN jsonb_build_object(
      'route', 'curation_direct', 'status', 'graph',
      'short_id', left(v_target_id::text, 8), 'title', v_title, 'items', v_items
    );
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(file_row) ORDER BY file_row.original_name), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT DISTINCT ON (attachment.storage_bucket, attachment.object_key)
      attachment.id::text AS attachment_id,
      attachment.storage_bucket AS bucket,
      attachment.object_key,
      coalesce(attachment.original_name, attachment.kind || '-' || left(attachment.id::text, 8)) AS original_name,
      attachment.mime_type,
      attachment.size_bytes
    FROM inbox.attachments attachment
    WHERE attachment.inbox_item_id = v_target_id
      AND attachment.storage_provider = 'backblaze_b2'
      AND attachment.upload_status = 'stored'
      AND attachment.storage_bucket IS NOT NULL
      AND attachment.object_key IS NOT NULL
    ORDER BY attachment.storage_bucket, attachment.object_key, attachment.created_at
  ) file_row;

  IF jsonb_array_length(v_items) = 0 THEN
    RETURN jsonb_build_object(
      'route', 'curation_direct', 'status', 'file_not_available',
      'short_id', left(v_target_id::text, 8), 'title', v_title
    );
  END IF;

  RETURN jsonb_build_object(
    'route', 'file_download', 'status', 'file_ready',
    'short_id', left(v_target_id::text, 8), 'title', v_title, 'attachments', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION inbox.execute_knowledge_access_command(bigint, text, text) FROM PUBLIC;

INSERT INTO inbox.schema_migrations (version)
VALUES ('009_pre_nest_access')
ON CONFLICT (version) DO NOTHING;

COMMIT;
