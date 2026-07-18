BEGIN;

CREATE TABLE IF NOT EXISTS inbox.pending_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES inbox.users(id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('delete')),
  target_inbox_item_id uuid REFERENCES inbox.inbox_items(id) ON DELETE SET NULL,
  confirmation_token text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'confirmed', 'completed', 'cancelled', 'expired', 'failed')),
  expires_at timestamptz NOT NULL,
  confirmed_at timestamptz,
  completed_at timestamptz,
  error_message text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS pending_actions_user_token_uidx
  ON inbox.pending_actions (user_id, confirmation_token);

CREATE INDEX IF NOT EXISTS pending_actions_pending_expiry_idx
  ON inbox.pending_actions (expires_at)
  WHERE status = 'pending';

DROP TRIGGER IF EXISTS pending_actions_set_updated_at ON inbox.pending_actions;
CREATE TRIGGER pending_actions_set_updated_at
BEFORE UPDATE ON inbox.pending_actions
FOR EACH ROW EXECUTE FUNCTION inbox.set_updated_at();

CREATE OR REPLACE FUNCTION inbox.execute_memory_command(
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
  v_argument text := lower(trim(coalesce(p_argument, '')));
  v_target_id uuid;
  v_target_count integer := 0;
  v_title text;
  v_token text;
  v_action inbox.pending_actions%ROWTYPE;
  v_items jsonb;
  v_item jsonb;
BEGIN
  SELECT * INTO v_user
  FROM inbox.users
  WHERE telegram_user_id = p_telegram_user_id
    AND status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'unauthorized');
  END IF;

  UPDATE inbox.pending_actions
  SET status = 'expired'
  WHERE user_id = v_user.id
    AND status = 'pending'
    AND expires_at <= now();

  IF v_command IN ('help', 'memory', '') THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'help');
  END IF;

  IF v_command = 'recent' THEN
    SELECT coalesce(jsonb_agg(to_jsonb(recent_row) ORDER BY recent_row.received_at DESC), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT
        left(item.id::text, 8) AS short_id,
        coalesce(knowledge.title, left(coalesce(item.normalized_text, item.raw_text, 'Без назви'), 80)) AS title,
        item.content_type,
        item.status,
        coalesce(knowledge.is_archived, false) AS is_archived,
        item.received_at
      FROM inbox.inbox_items item
      LEFT JOIN inbox.knowledge_items knowledge ON knowledge.inbox_item_id = item.id
      WHERE item.user_id = v_user.id
      ORDER BY item.received_at DESC
      LIMIT 10
    ) recent_row;
    RETURN jsonb_build_object('route', 'direct', 'status', 'recent', 'items', v_items);
  END IF;

  IF v_command IN ('confirm', 'cancel') THEN
    IF v_argument = '' THEN
      RETURN jsonb_build_object('route', 'direct', 'status', 'token_required');
    END IF;

    SELECT * INTO v_action
    FROM inbox.pending_actions
    WHERE user_id = v_user.id
      AND confirmation_token = upper(v_argument)
    ORDER BY created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('route', 'direct', 'status', 'action_not_found');
    END IF;

    IF v_command = 'cancel' THEN
      IF v_action.status = 'pending' THEN
        UPDATE inbox.pending_actions SET status = 'cancelled' WHERE id = v_action.id;
        RETURN jsonb_build_object('route', 'direct', 'status', 'cancelled');
      END IF;
      RETURN jsonb_build_object('route', 'direct', 'status', 'action_not_pending');
    END IF;

    IF v_action.status NOT IN ('pending', 'confirmed') OR v_action.target_inbox_item_id IS NULL THEN
      RETURN jsonb_build_object('route', 'direct', 'status', 'action_not_pending');
    END IF;

    IF v_action.status = 'pending' THEN
      IF v_action.expires_at <= now() THEN
        RETURN jsonb_build_object('route', 'direct', 'status', 'action_not_pending');
      END IF;
      UPDATE inbox.pending_actions
      SET status = 'confirmed', confirmed_at = now(), error_message = NULL
      WHERE id = v_action.id;
    END IF;

    SELECT coalesce(knowledge.title, left(coalesce(item.normalized_text, item.raw_text, 'Без назви'), 100))
    INTO v_title
    FROM inbox.inbox_items item
    LEFT JOIN inbox.knowledge_items knowledge ON knowledge.inbox_item_id = item.id
    WHERE item.id = v_action.target_inbox_item_id;

    RETURN jsonb_build_object(
      'route', 'confirm_delete',
      'status', 'confirmed',
      'action_id', v_action.id::text,
      'item_id', v_action.target_inbox_item_id::text,
      'title', coalesce(v_title, 'Без назви')
    );
  END IF;

  IF length(v_argument) < 6 OR v_argument !~ '^[0-9a-f-]+$' THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'item_id_required');
  END IF;

  SELECT count(*), (array_agg(item.id))[1]
  INTO v_target_count, v_target_id
  FROM inbox.inbox_items item
  WHERE item.user_id = v_user.id
    AND item.id::text LIKE v_argument || '%';

  IF v_target_count = 0 THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'item_not_found');
  ELSIF v_target_count > 1 THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'item_id_ambiguous');
  END IF;

  SELECT coalesce(knowledge.title, left(coalesce(item.normalized_text, item.raw_text, 'Без назви'), 100))
  INTO v_title
  FROM inbox.inbox_items item
  LEFT JOIN inbox.knowledge_items knowledge ON knowledge.inbox_item_id = item.id
  WHERE item.id = v_target_id;

  IF v_command = 'show' THEN
    SELECT jsonb_build_object(
      'short_id', left(item.id::text, 8),
      'title', coalesce(knowledge.title, v_title),
      'summary', coalesce(knowledge.summary, 'Аналіз ще не завершено'),
      'project', coalesce(project.name, 'Other'),
      'category', coalesce(category.name, 'Other'),
      'item_type', coalesce(item_type.name, item.content_type),
      'priority', coalesce(priority.name, 'Medium'),
      'tags', coalesce(tags.names, '[]'::jsonb),
      'status', item.status,
      'is_archived', coalesce(knowledge.is_archived, false),
      'received_at', item.received_at,
      'source_url', item.source_url,
      'attachments', coalesce(attachments.names, '[]'::jsonb)
    ) INTO v_item
    FROM inbox.inbox_items item
    LEFT JOIN inbox.knowledge_items knowledge ON knowledge.inbox_item_id = item.id
    LEFT JOIN inbox.projects project ON project.id = knowledge.project_id
    LEFT JOIN inbox.categories category ON category.id = knowledge.category_id
    LEFT JOIN inbox.item_types item_type ON item_type.id = knowledge.item_type_id
    LEFT JOIN inbox.priorities priority ON priority.id = knowledge.priority_id
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(tag.name ORDER BY tag.name) AS names
      FROM inbox.knowledge_item_tags kit
      JOIN inbox.tags tag ON tag.id = kit.tag_id
      WHERE kit.knowledge_item_id = knowledge.id
    ) tags ON true
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(coalesce(attachment.original_name, attachment.kind) ORDER BY attachment.created_at) AS names
      FROM inbox.attachments attachment
      WHERE attachment.inbox_item_id = item.id
    ) attachments ON true
    WHERE item.id = v_target_id;
    RETURN jsonb_build_object('route', 'direct', 'status', 'show', 'item', v_item);
  END IF;

  IF v_command = 'archive' THEN
    UPDATE inbox.knowledge_items SET is_archived = true WHERE inbox_item_id = v_target_id;
    RETURN jsonb_build_object('route', 'direct', 'status', 'archived', 'short_id', left(v_target_id::text, 8), 'title', v_title);
  END IF;

  IF v_command = 'delete' THEN
    UPDATE inbox.pending_actions
    SET status = 'cancelled'
    WHERE user_id = v_user.id AND target_inbox_item_id = v_target_id AND status = 'pending';

    LOOP
      v_token := upper(substr(encode(gen_random_bytes(5), 'hex'), 1, 8));
      EXIT WHEN NOT EXISTS (
        SELECT 1 FROM inbox.pending_actions
        WHERE user_id = v_user.id AND confirmation_token = v_token
      );
    END LOOP;

    INSERT INTO inbox.pending_actions (
      user_id, action, target_inbox_item_id, confirmation_token, expires_at,
      metadata
    ) VALUES (
      v_user.id, 'delete', v_target_id, v_token, now() + interval '10 minutes',
      jsonb_build_object('title', v_title)
    );
    RETURN jsonb_build_object(
      'route', 'direct', 'status', 'delete_confirmation',
      'short_id', left(v_target_id::text, 8), 'title', v_title,
      'token', v_token, 'expires_minutes', 10
    );
  END IF;

  IF v_command = 'reindex' THEN
    RETURN jsonb_build_object(
      'route', 'reindex', 'status', 'reindex_requested',
      'item_id', v_target_id::text, 'short_id', left(v_target_id::text, 8), 'title', v_title
    );
  END IF;

  RETURN jsonb_build_object('route', 'direct', 'status', 'help');
END;
$$;

REVOKE ALL ON FUNCTION inbox.execute_memory_command(bigint, text, text) FROM PUBLIC;

INSERT INTO inbox.schema_migrations (version)
VALUES ('006_memory_management')
ON CONFLICT (version) DO NOTHING;

COMMIT;
