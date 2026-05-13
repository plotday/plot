-- One-time cleanup of priority_block.duration leftovers from the old
-- session-close write-back behaviour. That path stored every closed
-- session's remaining time on the priority's "current" priority_block
-- row, which then masqueraded as the user's configured base duration on
-- the next Start press (typically 5-minute distraction remainders).
--
-- Now that pause state lives on the session row, priority_block.duration
-- is meant to be the user-configured base only. Heuristically clear:
--   * any value with non-zero seconds (the user picks whole minutes),
--   * any value ≤ 5 minutes (kDistractionPomodoro / kMinPomodoro).
-- The orderValue carried on the same row is preserved.
UPDATE public.priority_block
SET duration = NULL,
    updated_at = now()
WHERE duration IS NOT NULL
  AND (
    EXTRACT(SECOND FROM duration) <> 0
    OR duration <= INTERVAL '5 minutes'
  );
