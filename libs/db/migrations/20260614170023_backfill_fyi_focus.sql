-- Create one global, role-less FYI focus for every existing user that lacks
-- one. Filed as a child of the user's root (legacy ltree path still present).
-- No threads move — going-forward routing only.
INSERT INTO priority
    (id, created_by, user_id, title, path, color, key, role_id, is_fyi,
     early_notifications_enabled)
SELECT
    uuidv7(),
    r.created_by,
    r.user_id,
    'FYI',
    generate_path(r.path),
    0,
    'fyi',
    NULL,
    TRUE,
    FALSE
FROM priority r
WHERE nlevel(r.path) = 1            -- the user's root priority
  AND r.archived_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM priority f
      WHERE f.user_id = r.user_id AND f.is_fyi = TRUE AND f.archived_at IS NULL
  );
