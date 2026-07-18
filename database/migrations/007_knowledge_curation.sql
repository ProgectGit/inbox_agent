BEGIN;

CREATE OR REPLACE FUNCTION inbox.execute_knowledge_curation_command(
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
  v_argument_raw text := trim(coalesce(p_argument, ''));
  v_target_prefix text;
  v_edit_spec text;
  v_target_id uuid;
  v_target_count integer;
  v_knowledge_id uuid;
  v_title text;
  v_piece text;
  v_key text;
  v_value text;
  v_project_id uuid;
  v_category_id uuid;
  v_item_type_id uuid;
  v_priority_id uuid;
  v_new_title text;
  v_new_summary text;
  v_tags text;
  v_has_project boolean := false;
  v_has_category boolean := false;
  v_has_item_type boolean := false;
  v_has_priority boolean := false;
  v_has_title boolean := false;
  v_has_summary boolean := false;
  v_has_tags boolean := false;
  v_changes jsonb := '{}'::jsonb;
  v_items jsonb;
BEGIN
  SELECT * INTO v_user
  FROM inbox.users
  WHERE telegram_user_id = p_telegram_user_id
    AND status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'unauthorized');
  END IF;

  IF v_command = 'review' THEN
    SELECT coalesce(jsonb_agg(to_jsonb(review_row) ORDER BY review_row.received_at DESC), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT
        left(item.id::text, 8) AS short_id,
        coalesce(knowledge.title, left(coalesce(item.normalized_text, item.raw_text, 'Без назви'), 80)) AS title,
        item.status,
        array_remove(ARRAY[
          CASE WHEN item.status <> 'ready' THEN 'статус: ' || item.status END,
          CASE WHEN knowledge.id IS NULL THEN 'немає AI-аналізу' END,
          CASE WHEN project.name = 'Other' THEN 'проєкт не визначено' END,
          CASE WHEN category.name = 'Other' THEN 'категорію не визначено' END,
          CASE WHEN item.raw_payload #>> '{extraction,complete}' = 'false' THEN 'неповне вилучення тексту' END
        ], NULL) AS reasons,
        item.received_at
      FROM inbox.inbox_items item
      LEFT JOIN inbox.knowledge_items knowledge ON knowledge.inbox_item_id = item.id
      LEFT JOIN inbox.projects project ON project.id = knowledge.project_id
      LEFT JOIN inbox.categories category ON category.id = knowledge.category_id
      WHERE item.user_id = v_user.id
        AND coalesce(knowledge.is_archived, false) = false
        AND (
          item.status <> 'ready'
          OR knowledge.id IS NULL
          OR project.name = 'Other'
          OR category.name = 'Other'
          OR item.raw_payload #>> '{extraction,complete}' = 'false'
        )
      ORDER BY item.received_at DESC
      LIMIT 10
    ) review_row;

    RETURN jsonb_build_object('route', 'direct', 'status', 'review', 'items', v_items);
  END IF;

  IF v_command = 'edit' THEN
    v_target_prefix := lower(split_part(v_argument_raw, ' ', 1));
    v_edit_spec := trim(substr(v_argument_raw, length(split_part(v_argument_raw, ' ', 1)) + 1));
  ELSE
    v_target_prefix := lower(v_argument_raw);
    v_edit_spec := '';
  END IF;

  IF length(v_target_prefix) < 6 OR v_target_prefix !~ '^[0-9a-f-]+$' THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'item_id_required');
  END IF;

  SELECT count(*), (array_agg(item.id))[1]
  INTO v_target_count, v_target_id
  FROM inbox.inbox_items item
  WHERE item.user_id = v_user.id
    AND item.id::text LIKE v_target_prefix || '%';

  IF v_target_count = 0 THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'item_not_found');
  ELSIF v_target_count > 1 THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'item_id_ambiguous');
  END IF;

  SELECT knowledge.id, coalesce(knowledge.title, left(coalesce(item.normalized_text, item.raw_text, 'Без назви'), 100))
  INTO v_knowledge_id, v_title
  FROM inbox.inbox_items item
  LEFT JOIN inbox.knowledge_items knowledge ON knowledge.inbox_item_id = item.id
  WHERE item.id = v_target_id;

  IF v_command = 'unarchive' THEN
    UPDATE inbox.knowledge_items SET is_archived = false WHERE id = v_knowledge_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('route', 'direct', 'status', 'knowledge_not_ready');
    END IF;
    RETURN jsonb_build_object(
      'route', 'direct', 'status', 'unarchived',
      'short_id', left(v_target_id::text, 8), 'title', v_title
    );
  END IF;

  IF v_command = 'related' THEN
    IF v_knowledge_id IS NULL THEN
      RETURN jsonb_build_object('route', 'direct', 'status', 'knowledge_not_ready');
    END IF;

    SELECT coalesce(jsonb_agg(to_jsonb(related_row) ORDER BY related_row.score DESC, related_row.created_at DESC), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT
        left(candidate.inbox_item_id::text, 8) AS short_id,
        candidate.title,
        round(greatest(
          coalesce(stored_relation.score, 0),
          (CASE WHEN candidate.project_id IS NOT DISTINCT FROM target.project_id AND target.project_id IS NOT NULL THEN 0.30 ELSE 0 END)
          + (CASE WHEN candidate.category_id IS NOT DISTINCT FROM target.category_id AND target.category_id IS NOT NULL THEN 0.30 ELSE 0 END)
          + (CASE WHEN candidate.item_type_id IS NOT DISTINCT FROM target.item_type_id AND target.item_type_id IS NOT NULL THEN 0.10 ELSE 0 END)
          + least(coalesce(shared_tags.tag_count, 0) * 0.10, 0.30)
        )::numeric, 2) AS score,
        array_remove(ARRAY[
          CASE WHEN candidate.project_id IS NOT DISTINCT FROM target.project_id AND target.project_id IS NOT NULL THEN 'спільний проєкт' END,
          CASE WHEN candidate.category_id IS NOT DISTINCT FROM target.category_id AND target.category_id IS NOT NULL THEN 'спільна категорія' END,
          CASE WHEN candidate.item_type_id IS NOT DISTINCT FROM target.item_type_id AND target.item_type_id IS NOT NULL THEN 'спільний тип' END,
          CASE WHEN coalesce(shared_tags.tag_count, 0) > 0 THEN 'спільні теги: ' || shared_tags.tag_count END,
          CASE WHEN stored_relation.id IS NOT NULL THEN 'збережений зв’язок: ' || stored_relation.relation_type END
        ], NULL) AS reasons,
        candidate.created_at
      FROM inbox.knowledge_items target
      JOIN inbox.knowledge_items candidate
        ON candidate.user_id = target.user_id
       AND candidate.id <> target.id
       AND candidate.is_archived = false
      LEFT JOIN LATERAL (
        SELECT count(*)::integer AS tag_count
        FROM inbox.knowledge_item_tags target_tag
        JOIN inbox.knowledge_item_tags candidate_tag ON candidate_tag.tag_id = target_tag.tag_id
        WHERE target_tag.knowledge_item_id = target.id
          AND candidate_tag.knowledge_item_id = candidate.id
      ) shared_tags ON true
      LEFT JOIN inbox.relations stored_relation
        ON (stored_relation.source_item_id = target.id AND stored_relation.target_item_id = candidate.id)
        OR (stored_relation.target_item_id = target.id AND stored_relation.source_item_id = candidate.id)
      WHERE target.id = v_knowledge_id
        AND (
          candidate.project_id IS NOT DISTINCT FROM target.project_id
          OR candidate.category_id IS NOT DISTINCT FROM target.category_id
          OR candidate.item_type_id IS NOT DISTINCT FROM target.item_type_id
          OR coalesce(shared_tags.tag_count, 0) > 0
          OR stored_relation.id IS NOT NULL
        )
      ORDER BY score DESC, candidate.created_at DESC
      LIMIT 5
    ) related_row;

    RETURN jsonb_build_object(
      'route', 'direct', 'status', 'related',
      'short_id', left(v_target_id::text, 8), 'title', v_title, 'items', v_items
    );
  END IF;

  IF v_command <> 'edit' THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'help');
  END IF;

  IF v_knowledge_id IS NULL THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'knowledge_not_ready');
  END IF;

  IF v_edit_spec = '' THEN
    RETURN jsonb_build_object('route', 'direct', 'status', 'edit_spec_required');
  END IF;

  FOR v_piece IN SELECT trim(value) FROM regexp_split_to_table(v_edit_spec, '\s*;\s*') value
  LOOP
    IF position('=' IN v_piece) = 0 THEN
      RETURN jsonb_build_object('route', 'direct', 'status', 'edit_invalid_assignment', 'value', v_piece);
    END IF;
    v_key := lower(trim(split_part(v_piece, '=', 1)));
    v_value := trim(substr(v_piece, position('=' IN v_piece) + 1));

    IF v_key IN ('project', 'проєкт', 'проект') THEN
      SELECT id INTO v_project_id FROM inbox.projects
      WHERE is_active AND (lower(name) = lower(v_value) OR lower(slug) = lower(v_value));
      IF NOT FOUND THEN RETURN jsonb_build_object('route', 'direct', 'status', 'edit_unknown_value', 'field', 'project', 'value', v_value); END IF;
      v_has_project := true;
      v_changes := v_changes || jsonb_build_object('project', v_value);
    ELSIF v_key IN ('category', 'категорія') THEN
      SELECT id INTO v_category_id FROM inbox.categories
      WHERE is_active AND (lower(name) = lower(v_value) OR lower(slug) = lower(v_value));
      IF NOT FOUND THEN RETURN jsonb_build_object('route', 'direct', 'status', 'edit_unknown_value', 'field', 'category', 'value', v_value); END IF;
      v_has_category := true;
      v_changes := v_changes || jsonb_build_object('category', v_value);
    ELSIF v_key IN ('type', 'тип') THEN
      SELECT id INTO v_item_type_id FROM inbox.item_types
      WHERE is_active AND (lower(name) = lower(v_value) OR lower(slug) = lower(v_value));
      IF NOT FOUND THEN RETURN jsonb_build_object('route', 'direct', 'status', 'edit_unknown_value', 'field', 'type', 'value', v_value); END IF;
      v_has_item_type := true;
      v_changes := v_changes || jsonb_build_object('type', v_value);
    ELSIF v_key IN ('priority', 'пріоритет') THEN
      SELECT id INTO v_priority_id FROM inbox.priorities
      WHERE lower(name) = lower(v_value) OR lower(slug) = lower(v_value);
      IF NOT FOUND THEN RETURN jsonb_build_object('route', 'direct', 'status', 'edit_unknown_value', 'field', 'priority', 'value', v_value); END IF;
      v_has_priority := true;
      v_changes := v_changes || jsonb_build_object('priority', v_value);
    ELSIF v_key IN ('title', 'назва') THEN
      IF v_value = '' THEN RETURN jsonb_build_object('route', 'direct', 'status', 'edit_empty_value', 'field', 'title'); END IF;
      v_new_title := v_value;
      v_has_title := true;
      v_changes := v_changes || jsonb_build_object('title', v_value);
    ELSIF v_key IN ('summary', 'резюме') THEN
      IF v_value = '' THEN RETURN jsonb_build_object('route', 'direct', 'status', 'edit_empty_value', 'field', 'summary'); END IF;
      v_new_summary := v_value;
      v_has_summary := true;
      v_changes := v_changes || jsonb_build_object('summary', v_value);
    ELSIF v_key IN ('tags', 'теги') THEN
      v_tags := v_value;
      v_has_tags := true;
      v_changes := v_changes || jsonb_build_object('tags', v_value);
    ELSE
      RETURN jsonb_build_object('route', 'direct', 'status', 'edit_unknown_field', 'field', v_key);
    END IF;
  END LOOP;

  UPDATE inbox.knowledge_items
  SET project_id = CASE WHEN v_has_project THEN v_project_id ELSE project_id END,
      category_id = CASE WHEN v_has_category THEN v_category_id ELSE category_id END,
      item_type_id = CASE WHEN v_has_item_type THEN v_item_type_id ELSE item_type_id END,
      priority_id = CASE WHEN v_has_priority THEN v_priority_id ELSE priority_id END,
      title = CASE WHEN v_has_title THEN v_new_title ELSE title END,
      summary = CASE WHEN v_has_summary THEN v_new_summary ELSE summary END,
      metadata = metadata || jsonb_build_object(
        'last_manual_edit_at', now(),
        'last_manual_edit_source', 'telegram'
      )
  WHERE id = v_knowledge_id;

  IF v_has_tags THEN
    DELETE FROM inbox.knowledge_item_tags WHERE knowledge_item_id = v_knowledge_id;
    IF trim(coalesce(v_tags, '')) <> '' THEN
      WITH tag_values AS (
        SELECT DISTINCT trim(value) AS name, lower(trim(value)) AS normalized_name
        FROM regexp_split_to_table(v_tags, '\s*,\s*') value
        WHERE trim(value) <> ''
      ), inserted AS (
        INSERT INTO inbox.tags (name, normalized_name)
        SELECT name, normalized_name FROM tag_values
        ON CONFLICT (normalized_name) DO UPDATE SET name = EXCLUDED.name
        RETURNING id, normalized_name
      )
      INSERT INTO inbox.knowledge_item_tags (knowledge_item_id, tag_id)
      SELECT v_knowledge_id, inserted.id
      FROM inserted
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'route', 'reindex', 'status', 'edited',
    'item_id', v_target_id::text,
    'short_id', left(v_target_id::text, 8),
    'title', coalesce(v_new_title, v_title),
    'changes', v_changes
  );
END;
$$;

REVOKE ALL ON FUNCTION inbox.execute_knowledge_curation_command(bigint, text, text) FROM PUBLIC;

INSERT INTO inbox.schema_migrations (version)
VALUES ('007_knowledge_curation')
ON CONFLICT (version) DO NOTHING;

COMMIT;
