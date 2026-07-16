BEGIN;

INSERT INTO inbox.users (
  telegram_user_id,
  telegram_chat_id,
  username,
  display_name,
  locale,
  role,
  status
)
VALUES (
  :'telegram_user_id'::bigint,
  :'telegram_chat_id'::bigint,
  NULLIF(:'username', ''),
  :'display_name',
  :'locale',
  'owner',
  'active'
)
ON CONFLICT (telegram_user_id) DO UPDATE
SET telegram_chat_id = EXCLUDED.telegram_chat_id,
    username = EXCLUDED.username,
    display_name = EXCLUDED.display_name,
    locale = EXCLUDED.locale,
    role = 'owner',
    status = 'active';

INSERT INTO inbox.schema_migrations (version)
VALUES ('003_seed_owner')
ON CONFLICT (version) DO NOTHING;

COMMIT;
