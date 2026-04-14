CREATE TABLE IF NOT EXISTS twist_instance_sync (
  twist_instance_id uuid NOT NULL REFERENCES twist_instance(id) ON DELETE CASCADE,
  entity text NOT NULL,
  operation sync_operation NOT NULL,
  last_update_at timestamptz NOT NULL,
  last_sync_at timestamptz NOT NULL DEFAULT '1970-01-01'::timestamptz,
  PRIMARY KEY (twist_instance_id, entity, operation)
);

-- Index for querying pending updates
CREATE INDEX IF NOT EXISTS idx_twist_instance_sync_pending ON twist_instance_sync (twist_instance_id)
  WHERE last_update_at > last_sync_at;
