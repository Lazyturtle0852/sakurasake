CREATE TABLE IF NOT EXISTS feed_items (
  id BIGSERIAL PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('post', 'comment')),
  who TEXT,
  "from" TEXT,
  content TEXT,
  img TEXT,
  likes INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_feed_items_created_at ON feed_items (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_feed_items_post_match ON feed_items (kind, who, content, created_at DESC);
