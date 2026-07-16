BEGIN;

INSERT INTO inbox.categories (slug, name)
VALUES
  ('programming', 'Programming'),
  ('ai', 'AI'),
  ('medicine', 'Medicine'),
  ('backend', 'Backend'),
  ('frontend', 'Frontend'),
  ('flutter', 'Flutter'),
  ('javascript', 'JavaScript'),
  ('typescript', 'TypeScript'),
  ('node-js', 'Node.js'),
  ('nestjs', 'NestJS'),
  ('postgresql', 'PostgreSQL'),
  ('docker', 'Docker'),
  ('devops', 'DevOps'),
  ('wordpress', 'WordPress'),
  ('shopify', 'Shopify'),
  ('seo', 'SEO'),
  ('marketing', 'Marketing'),
  ('business', 'Business'),
  ('finance', 'Finance'),
  ('crypto', 'Crypto'),
  ('hardware', 'Hardware'),
  ('books', 'Books'),
  ('courses', 'Courses'),
  ('research', 'Research'),
  ('ideas', 'Ideas'),
  ('personal', 'Personal'),
  ('work', 'Work'),
  ('family', 'Family'),
  ('health', 'Health'),
  ('other', 'Other')
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    is_active = true;

INSERT INTO inbox.projects (slug, name)
VALUES
  ('panakea', 'Panakea'),
  ('ai-studio', 'AI Studio'),
  ('second-brain', 'Second Brain'),
  ('dashboard', 'Dashboard'),
  ('shopify-studio', 'Shopify Studio'),
  ('safemind', 'SafeMind'),
  ('academy', 'Academy'),
  ('personal', 'Personal'),
  ('work', 'Work'),
  ('other', 'Other')
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    is_active = true;

INSERT INTO inbox.item_types (slug, name)
VALUES
  ('idea', 'Idea'),
  ('task', 'Task'),
  ('question', 'Question'),
  ('research', 'Research'),
  ('article', 'Article'),
  ('book', 'Book'),
  ('course', 'Course'),
  ('video', 'Video'),
  ('screenshot', 'Screenshot'),
  ('document', 'Document'),
  ('bug', 'Bug'),
  ('feature', 'Feature'),
  ('reminder', 'Reminder'),
  ('conversation', 'Conversation'),
  ('snippet', 'Snippet'),
  ('meeting', 'Meeting')
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    is_active = true;

INSERT INTO inbox.priorities (slug, name, rank)
VALUES
  ('critical', 'Critical', 1),
  ('high', 'High', 2),
  ('medium', 'Medium', 3),
  ('low', 'Low', 4)
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    rank = EXCLUDED.rank;

INSERT INTO inbox.schema_migrations (version)
VALUES ('002_seed_taxonomy')
ON CONFLICT (version) DO NOTHING;

COMMIT;
