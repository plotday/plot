-- Archive removed twists: calendar-sync, code-review, document-actions, project-sync
-- These are replaced by individual sources that users install directly.

DO $$
DECLARE
  v_package_ids uuid[] := ARRAY[
    '0199b6f4-85b8-7b21-aeb2-ac4169e351af',  -- calendar-sync
    'd4c81f01-3f43-5304-bdb1-81c77c1c713c',  -- code-review
    'a7e1c4d2-5f38-4b91-9d06-8c2e3a1f7b54',  -- document-actions
    'c3b70e90-2e32-4293-adc0-70b66b0b602b'   -- project-sync
  ];
  v_twist_ids bigint[];
  v_priority_twist_ids uuid[];
BEGIN
  -- Find twist.id values for the removed packages
  SELECT array_agg(t.id) INTO v_twist_ids
  FROM twist t
  JOIN twist_admin ta ON ta.id = t.twist_admin_id
  WHERE ta.twist_package_id = ANY(v_package_ids);

  -- If no twist records found, nothing to do
  IF v_twist_ids IS NULL THEN
    RAISE NOTICE 'No twist records found for the specified package IDs';
    RETURN;
  END IF;

  -- Find active priority_twist records
  SELECT array_agg(pt.id) INTO v_priority_twist_ids
  FROM priority_twist pt
  WHERE pt.twist_id = ANY(v_twist_ids)
    AND pt.archived_at IS NULL;

  -- 1. Archive threads created by these priority_twists
  IF v_priority_twist_ids IS NOT NULL THEN
    UPDATE thread
    SET archived_at = NOW()
    WHERE created_by = ANY(v_priority_twist_ids)
      AND archived_at IS NULL;

    RAISE NOTICE 'Archived threads for % priority_twists', array_length(v_priority_twist_ids, 1);

    -- 2. Archive the priority_twist records
    UPDATE priority_twist
    SET archived_at = NOW()
    WHERE id = ANY(v_priority_twist_ids);

    RAISE NOTICE 'Archived % priority_twists', array_length(v_priority_twist_ids, 1);
  END IF;

  -- 3. Archive the twist records (prevents new installations)
  UPDATE twist
  SET archived_at = NOW()
  WHERE id = ANY(v_twist_ids)
    AND archived_at IS NULL;

  RAISE NOTICE 'Archived % twist records', array_length(v_twist_ids, 1);
END $$;
