-- Backfill icon for threads created by connectors/twists before the icon column existed.
-- Excludes threads created by the Plot built-in tool (user-created threads),
-- which should keep NULL for sub-type defaults.
UPDATE thread t
SET icon = 'twist:' || pt.twist_id
FROM priority_twist pt
JOIN twist tw ON tw.id = pt.twist_id
WHERE pt.id = t.created_by
  AND t.icon IS NULL
  AND tw.name != 'Plot';
