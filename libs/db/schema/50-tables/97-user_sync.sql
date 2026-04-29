CREATE TABLE IF NOT EXISTS user_sync (
  user_id uuid NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
  entity text NOT NULL,
  last_update_at timestamptz NOT NULL,
  last_sync_at timestamptz NOT NULL DEFAULT '1970-01-01'::timestamptz,
  -- xid8 watermark counterparts of last_update_at / last_sync_at. Bumped by
  -- the sync_user_for_* triggers alongside last_update_at and consulted by
  -- the UserSync DO to decide what to broadcast. Replaces last_update_at
  -- (subject to the long-transaction race) once the expand-contract rollout
  -- completes.
  last_update_seq xid8 NOT NULL DEFAULT '0'::xid8,
  last_sync_seq xid8 NOT NULL DEFAULT '0'::xid8,
  PRIMARY KEY (user_id, entity)
);

-- Index for querying pending updates
CREATE INDEX IF NOT EXISTS idx_user_sync_pending ON user_sync (user_id)
  WHERE last_update_at > last_sync_at;

CREATE INDEX IF NOT EXISTS idx_user_sync_pending_seq ON user_sync (user_id)
  WHERE last_update_seq > last_sync_seq;
