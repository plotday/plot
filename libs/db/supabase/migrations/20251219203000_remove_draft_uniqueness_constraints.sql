-- Remove draft uniqueness constraints to allow multiple drafts per scope
-- This simplifies draft management by removing archiving logic

-- Drop the unique index on draft activities per user per priority
DROP INDEX IF EXISTS idx_activity_unique_draft_per_user_priority;

-- Drop the unique index on draft notes per user per activity
DROP INDEX IF EXISTS idx_note_unique_draft_per_user_activity;
