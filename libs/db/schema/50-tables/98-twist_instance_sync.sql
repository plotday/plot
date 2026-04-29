CREATE TABLE IF NOT EXISTS twist_instance_sync (
  twist_instance_id uuid NOT NULL REFERENCES twist_instance(id) ON DELETE CASCADE,
  entity text NOT NULL,
  operation sync_operation NOT NULL,
  last_update_at timestamptz NOT NULL,
  last_sync_at timestamptz NOT NULL DEFAULT '1970-01-01'::timestamptz,
  -- xid8 watermark counterparts of last_update_at / last_sync_at. Bumped by the
  -- sync_twist_for_* triggers alongside last_update_at and consulted by the
  -- TwistSync DO. Replaces the timestamp cursor (subject to the
  -- long-transaction cursor-skip race -- see workers/api/src/app/sync/helpers.ts
  -- and commit 063ce93f8 for context).
  last_update_seq xid8 NOT NULL DEFAULT '0'::xid8,
  last_sync_seq xid8 NOT NULL DEFAULT '0'::xid8,
  PRIMARY KEY (twist_instance_id, entity, operation)
);

-- Index for querying pending updates
CREATE INDEX IF NOT EXISTS idx_twist_instance_sync_pending ON twist_instance_sync (twist_instance_id)
  WHERE last_update_at > last_sync_at;

CREATE INDEX IF NOT EXISTS idx_twist_instance_sync_pending_seq ON twist_instance_sync (twist_instance_id)
  WHERE last_update_seq > last_sync_seq;
