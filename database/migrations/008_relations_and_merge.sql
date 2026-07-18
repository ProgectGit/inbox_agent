BEGIN;

ALTER TABLE inbox.pending_actions
  DROP CONSTRAINT IF EXISTS pending_actions_action_check;

ALTER TABLE inbox.pending_actions
  ADD CONSTRAINT pending_actions_action_check
  CHECK (action IN ('delete', 'merge'));

CREATE INDEX IF NOT EXISTS relations_source_idx
  ON inbox.relations (source_item_id, relation_type);

CREATE OR REPLACE FUNCTION inbox.execute_relation_command(
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
  v_argument text := trim(coalesce(p_argument, ''));
  v_source_prefix text;
  v_canonical_prefix text;
  v_source_id uuid;
  v_canonical_id uuid;
  v_count integer;
  v_source_title text;
  v_canonical_title text;
  v_token text;
  v_action inbox.pending_actions%ROWTYPE;
BEGIN
  SELECT * INTO v_user
  FROM inbox.users
  WHERE telegram_user_id = p_telegram_user_id AND status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'unauthorized');
  END IF;

  IF v_command = 'confirm' THEN
    SELECT * INTO v_action
    FROM inbox.pending_actions
    WHERE user_id = v_user.id
      AND confirmation_token = upper(v_argument)
      AND action = 'merge'
    ORDER BY created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('route', 'delegate');
    END IF;

    IF v_action.status NOT IN ('pending', 'confirmed')
      OR v_action.target_inbox_item_id IS NULL
      OR nullif(v_action.metadata->>'canonical_inbox_item_id', '') IS NULL THEN
      RETURN jsonb_build_object('route', 'curation_direct', 'status', 'action_not_pending');
    END IF;

    IF v_action.status = 'pending' THEN
      IF v_action.expires_at <= now() THEN
        UPDATE inbox.pending_actions SET status = 'expired' WHERE id = v_action.id;
        RETURN jsonb_build_object('route', 'curation_direct', 'status', 'action_not_pending');
      END IF;
      UPDATE inbox.pending_actions
      SET status = 'confirmed', confirmed_at = now(), error_message = NULL
      WHERE id = v_action.id;
    END IF;

    RETURN jsonb_build_object(
      'route', 'confirm_merge',
      'status', 'confirmed',
      'action_id', v_action.id::text,
      'source_item_id', v_action.target_inbox_item_id::text,
      'canonical_item_id', v_action.metadata->>'canonical_inbox_item_id',
      'source_title', v_action.metadata->>'source_title',
      'canonical_title', v_action.metadata->>'canonical_title'
    );
  END IF;

  IF v_command <> 'merge' THEN
    RETURN jsonb_build_object('route', 'delegate');
  END IF;

  v_source_prefix := lower(split_part(v_argument, ' ', 1));
  v_canonical_prefix := lower(split_part(trim(substr(v_argument, length(split_part(v_argument, ' ', 1)) + 1)), ' ', 1));

  IF length(v_source_prefix) < 6 OR length(v_canonical_prefix) < 6
    OR v_source_prefix !~ '^[0-9a-f-]+$' OR v_canonical_prefix !~ '^[0-9a-f-]+$' THEN
    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'merge_ids_required');
  END IF;

  SELECT count(*), (array_agg(item.id))[1]
  INTO v_count, v_source_id
  FROM inbox.inbox_items item
  WHERE item.user_id = v_user.id AND item.id::text LIKE v_source_prefix || '%';

  IF v_count = 0 THEN RETURN jsonb_build_object('route', 'curation_direct', 'status', 'item_not_found'); END IF;
  IF v_count > 1 THEN RETURN jsonb_build_object('route', 'curation_direct', 'status', 'item_id_ambiguous'); END IF;

  SELECT count(*), (array_agg(item.id))[1]
  INTO v_count, v_canonical_id
  FROM inbox.inbox_items item
  WHERE item.user_id = v_user.id AND item.id::text LIKE v_canonical_prefix || '%';

  IF v_count = 0 THEN RETURN jsonb_build_object('route', 'curation_direct', 'status', 'item_not_found'); END IF;
  IF v_count > 1 THEN RETURN jsonb_build_object('route', 'curation_direct', 'status', 'item_id_ambiguous'); END IF;
  IF v_source_id = v_canonical_id THEN
    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'merge_same_item');
  END IF;

  SELECT knowledge.title INTO v_source_title
  FROM inbox.knowledge_items knowledge WHERE knowledge.inbox_item_id = v_source_id;
  SELECT knowledge.title INTO v_canonical_title
  FROM inbox.knowledge_items knowledge WHERE knowledge.inbox_item_id = v_canonical_id;

  IF v_source_title IS NULL OR v_canonical_title IS NULL THEN
    RETURN jsonb_build_object('route', 'curation_direct', 'status', 'knowledge_not_ready');
  END IF;

  UPDATE inbox.pending_actions
  SET status = 'cancelled'
  WHERE user_id = v_user.id AND action = 'merge'
    AND target_inbox_item_id = v_source_id AND status = 'pending';

  LOOP
    v_token := upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 8));
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM inbox.pending_actions
      WHERE user_id = v_user.id AND confirmation_token = v_token
    );
  END LOOP;

  INSERT INTO inbox.pending_actions (
    user_id, action, target_inbox_item_id, confirmation_token, expires_at, metadata
  ) VALUES (
    v_user.id, 'merge', v_source_id, v_token, now() + interval '10 minutes',
    jsonb_build_object(
      'canonical_inbox_item_id', v_canonical_id::text,
      'source_title', v_source_title,
      'canonical_title', v_canonical_title
    )
  );

  RETURN jsonb_build_object(
    'route', 'curation_direct',
    'status', 'merge_confirmation',
    'source_short_id', left(v_source_id::text, 8),
    'canonical_short_id', left(v_canonical_id::text, 8),
    'source_title', v_source_title,
    'canonical_title', v_canonical_title,
    'token', v_token,
    'expires_minutes', 10
  );
END;
$$;

REVOKE ALL ON FUNCTION inbox.execute_relation_command(bigint, text, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION inbox.finalize_merge_action(p_action_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = inbox, public
AS $$
DECLARE
  v_action inbox.pending_actions%ROWTYPE;
  v_source_item_id uuid;
  v_canonical_item_id uuid;
  v_source_knowledge_id uuid;
  v_canonical_knowledge_id uuid;
  v_source_title text;
  v_canonical_title text;
  v_moved_attachments integer := 0;
  v_moved_tags integer := 0;
BEGIN
  SELECT * INTO v_action
  FROM inbox.pending_actions
  WHERE id = p_action_id AND action = 'merge' AND status = 'confirmed'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('merged', false, 'status', 'action_not_confirmed');
  END IF;

  v_source_item_id := v_action.target_inbox_item_id;
  v_canonical_item_id := (v_action.metadata->>'canonical_inbox_item_id')::uuid;

  SELECT id, title INTO v_source_knowledge_id, v_source_title
  FROM inbox.knowledge_items WHERE inbox_item_id = v_source_item_id;
  SELECT id, title INTO v_canonical_knowledge_id, v_canonical_title
  FROM inbox.knowledge_items WHERE inbox_item_id = v_canonical_item_id;

  IF v_source_knowledge_id IS NULL OR v_canonical_knowledge_id IS NULL THEN
    UPDATE inbox.pending_actions
    SET status = 'failed', error_message = 'Source or canonical knowledge item is missing'
    WHERE id = p_action_id;
    RETURN jsonb_build_object('merged', false, 'status', 'knowledge_not_ready');
  END IF;

  INSERT INTO inbox.knowledge_item_tags (knowledge_item_id, tag_id)
  SELECT v_canonical_knowledge_id, tag_id
  FROM inbox.knowledge_item_tags
  WHERE knowledge_item_id = v_source_knowledge_id
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_moved_tags = ROW_COUNT;

  UPDATE inbox.attachments
  SET inbox_item_id = v_canonical_item_id
  WHERE inbox_item_id = v_source_item_id;
  GET DIAGNOSTICS v_moved_attachments = ROW_COUNT;

  UPDATE inbox.documents
  SET knowledge_item_id = v_canonical_knowledge_id
  WHERE knowledge_item_id = v_source_knowledge_id;

  UPDATE inbox.memories
  SET source_knowledge_item_id = v_canonical_knowledge_id
  WHERE source_knowledge_item_id = v_source_knowledge_id;

  INSERT INTO inbox.relations (
    source_item_id, target_item_id, relation_type, score, explanation, created_by
  )
  SELECT
    CASE WHEN relation.source_item_id = v_source_knowledge_id THEN v_canonical_knowledge_id ELSE relation.source_item_id END,
    CASE WHEN relation.target_item_id = v_source_knowledge_id THEN v_canonical_knowledge_id ELSE relation.target_item_id END,
    relation.relation_type, relation.score,
    concat(coalesce(relation.explanation, ''), ' [перенесено під час merge]'),
    relation.created_by
  FROM inbox.relations relation
  WHERE (relation.source_item_id = v_source_knowledge_id OR relation.target_item_id = v_source_knowledge_id)
    AND (CASE WHEN relation.source_item_id = v_source_knowledge_id THEN v_canonical_knowledge_id ELSE relation.source_item_id END)
      <> (CASE WHEN relation.target_item_id = v_source_knowledge_id THEN v_canonical_knowledge_id ELSE relation.target_item_id END)
  ON CONFLICT (source_item_id, target_item_id, relation_type) DO UPDATE SET
    score = greatest(inbox.relations.score, EXCLUDED.score),
    explanation = EXCLUDED.explanation;

  DELETE FROM inbox.relations
  WHERE source_item_id = v_source_knowledge_id OR target_item_id = v_source_knowledge_id;

  UPDATE inbox.knowledge_items canonical
  SET content = CASE
        WHEN position(source.content IN canonical.content) > 0 THEN canonical.content
        ELSE canonical.content || E'\n\n--- Об’єднано з ' || left(v_source_item_id::text, 8) || E' ---\n' || source.content
      END,
      next_actions = (
        SELECT coalesce(jsonb_agg(DISTINCT value), '[]'::jsonb)
        FROM jsonb_array_elements(canonical.next_actions || source.next_actions) value
      ),
      metadata = canonical.metadata || jsonb_build_object(
        'merged_sources', coalesce(canonical.metadata->'merged_sources', '[]'::jsonb)
          || jsonb_build_array(jsonb_build_object(
            'inbox_item_id', v_source_item_id::text,
            'title', v_source_title,
            'merged_at', now()
          )),
        'last_merge_at', now()
      )
  FROM inbox.knowledge_items source
  WHERE canonical.id = v_canonical_knowledge_id AND source.id = v_source_knowledge_id;

  UPDATE inbox.processing_jobs
  SET status = 'cancelled', locked_at = NULL, locked_by = NULL
  WHERE inbox_item_id IN (v_source_item_id, v_canonical_item_id)
    AND status IN ('pending', 'running', 'failed');

  DELETE FROM inbox.knowledge_chunks WHERE knowledge_item_id = v_canonical_knowledge_id;

  UPDATE inbox.pending_actions
  SET status = 'completed', completed_at = now(), error_message = NULL
  WHERE id = p_action_id;

  DELETE FROM inbox.inbox_items WHERE id = v_source_item_id;

  INSERT INTO inbox.processing_jobs (inbox_item_id, job_type, status, payload)
  VALUES (v_canonical_item_id, 'index', 'pending', jsonb_build_object('reason', 'telegram_merge'));

  UPDATE inbox.inbox_items
  SET status = 'indexing', error_code = NULL, error_message = NULL
  WHERE id = v_canonical_item_id;

  RETURN jsonb_build_object(
    'merged', true,
    'source_short_id', left(v_source_item_id::text, 8),
    'canonical_short_id', left(v_canonical_item_id::text, 8),
    'source_title', v_source_title,
    'canonical_title', v_canonical_title,
    'canonical_item_id', v_canonical_item_id::text,
    'moved_attachments', v_moved_attachments,
    'moved_tags', v_moved_tags
  );
END;
$$;

REVOKE ALL ON FUNCTION inbox.finalize_merge_action(uuid) FROM PUBLIC;

INSERT INTO inbox.schema_migrations (version)
VALUES ('008_relations_and_merge')
ON CONFLICT (version) DO NOTHING;

COMMIT;
