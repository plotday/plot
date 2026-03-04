-- Rename activity→thread and links→actions across the entire database.
-- This migration drops all dependent objects, renames types/tables/columns/constraints/indexes,
-- then recreates objects via subsequent schema-generated migrations.

-- Ensure all objects are visible without schema qualification
SET search_path = public, "user";

------------------------------------------------------------
-- Phase 1: Drop all views (CASCADE) in reverse dependency order
------------------------------------------------------------

-- User schema views (depend on public views)
DROP VIEW IF EXISTS "user".priority_unread CASCADE;
DROP VIEW IF EXISTS "user".note CASCADE;
DROP VIEW IF EXISTS "user".activity CASCADE;
DROP VIEW IF EXISTS "user".priority CASCADE;

-- Public twist callback views (depend on activity_x, activity_tags)
DROP VIEW IF EXISTS public.priority_twist_note_update CASCADE;
DROP VIEW IF EXISTS public.priority_twist_note_create CASCADE;
DROP VIEW IF EXISTS public.priority_twist_activity_tag_change CASCADE;
DROP VIEW IF EXISTS public.priority_twist_activity_update CASCADE;
DROP VIEW IF EXISTS public.priority_twist_activity_create CASCADE;

-- Public aggregate views
DROP VIEW IF EXISTS public.priority_tags CASCADE;
DROP VIEW IF EXISTS public.activity_x CASCADE;
DROP VIEW IF EXISTS public.activity_tags CASCADE;
DROP VIEW IF EXISTS public.note_tags CASCADE;

-- Public priority views that may reference activity
DROP VIEW IF EXISTS public.priority_x CASCADE;

------------------------------------------------------------
-- Phase 2: Drop all triggers that reference old names
------------------------------------------------------------

-- Triggers on activity table
DROP TRIGGER IF EXISTS set_activity_updated_at ON activity;
DROP TRIGGER IF EXISTS set_activity_created_at ON activity;
DROP TRIGGER IF EXISTS set_activity_author_and_created_by ON activity;
DROP TRIGGER IF EXISTS user_sync_activity_insert ON activity;
DROP TRIGGER IF EXISTS user_sync_activity_update ON activity;
DROP TRIGGER IF EXISTS twist_sync_activity_insert ON activity;
DROP TRIGGER IF EXISTS twist_sync_activity_update ON activity;
DROP TRIGGER IF EXISTS set_activity_order_on_start_trigger ON activity;
DROP TRIGGER IF EXISTS set_activity_source_priority_root_trigger ON activity;
DROP TRIGGER IF EXISTS protect_activity_created_by_trigger ON activity;
DROP TRIGGER IF EXISTS enforce_activity_draft_rules_trigger ON activity;
DROP TRIGGER IF EXISTS ensure_assignee_priority_contact_trigger ON activity;

-- Triggers on note table that reference activity
DROP TRIGGER IF EXISTS update_activity_last_note_created_at_trigger ON note;
DROP TRIGGER IF EXISTS update_activity_last_note_created_at_on_status_change ON note;

-- Triggers on activity_read table
DROP TRIGGER IF EXISTS set_activity_read_updated_at ON activity_read;
DROP TRIGGER IF EXISTS user_sync_activity_read_insert ON activity_read;
DROP TRIGGER IF EXISTS user_sync_activity_read_update ON activity_read;

-- Triggers on activity_exception table
DROP TRIGGER IF EXISTS set_activity_exception_updated_at ON activity_exception;
DROP TRIGGER IF EXISTS set_activity_exception_created_at ON activity_exception;

-- Triggers on activity_tag table
DROP TRIGGER IF EXISTS set_activity_tag_updated_at ON activity_tag;
DROP TRIGGER IF EXISTS user_sync_activity_tag_insert ON activity_tag;
DROP TRIGGER IF EXISTS user_sync_activity_tag_update ON activity_tag;
DROP TRIGGER IF EXISTS twist_sync_activity_tag_insert ON activity_tag;
DROP TRIGGER IF EXISTS twist_sync_activity_tag_update ON activity_tag;

-- Triggers on activity_user_state table
DROP TRIGGER IF EXISTS set_activity_user_state_updated_at ON activity_user_state;
DROP TRIGGER IF EXISTS user_sync_activity_user_state_insert ON activity_user_state;
DROP TRIGGER IF EXISTS user_sync_activity_user_state_update ON activity_user_state;

------------------------------------------------------------
-- Phase 3: Drop all functions that reference old names (CASCADE)
------------------------------------------------------------

-- Public schema functions with 'activity' in the name
DROP FUNCTION IF EXISTS public.sync_user_for_activity CASCADE;
DROP FUNCTION IF EXISTS public.sync_user_for_activity_read CASCADE;
DROP FUNCTION IF EXISTS public.sync_user_for_activity_tag CASCADE;
DROP FUNCTION IF EXISTS public.sync_user_for_activity_user_state CASCADE;
DROP FUNCTION IF EXISTS public.sync_twist_for_activity CASCADE;
DROP FUNCTION IF EXISTS public.sync_twist_for_activity_tag CASCADE;
DROP FUNCTION IF EXISTS public.set_activity_order_on_start CASCADE;
DROP FUNCTION IF EXISTS public.set_activity_source_priority_root CASCADE;
DROP FUNCTION IF EXISTS public.protect_activity_created_by CASCADE;
DROP FUNCTION IF EXISTS public.get_activity_mentions CASCADE;
DROP FUNCTION IF EXISTS public.ensure_assignee_priority_contact CASCADE;
DROP FUNCTION IF EXISTS public.find_matching_activities_scored CASCADE;
DROP FUNCTION IF EXISTS public.find_similar_activities CASCADE;
DROP FUNCTION IF EXISTS public.update_activity_on_note_change CASCADE;

-- User schema functions with 'activity' in the name
DROP FUNCTION IF EXISTS "user".mentioned_in_activity CASCADE;
DROP FUNCTION IF EXISTS "user".update_activity_tags CASCADE;
DROP FUNCTION IF EXISTS "user".upsert_activity CASCADE;
DROP FUNCTION IF EXISTS "user".upsert_activity_tag CASCADE;
DROP FUNCTION IF EXISTS "user".upsert_activity_exception CASCADE;
DROP FUNCTION IF EXISTS "user".upsert_activity_read CASCADE;
DROP FUNCTION IF EXISTS "user".delete_activity_read CASCADE;
DROP FUNCTION IF EXISTS "user".upsert_activity_user_state CASCADE;
DROP FUNCTION IF EXISTS "user".delete_activity_user_state CASCADE;

-- User schema functions that reference old column names (need to be recreated)
DROP FUNCTION IF EXISTS "user".upsert_note CASCADE;

------------------------------------------------------------
-- Phases 4-9: Rename types, tables, columns, sequences, constraints, indexes
-- Wrapped in DO block so already-renamed objects don't cause errors
------------------------------------------------------------

DO $$
BEGIN
  -- Phase 4: Rename types
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'activity_kind') THEN
    ALTER TYPE public.activity_kind RENAME TO thread_kind;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_type WHERE typname = 'activity_type') THEN
    ALTER TYPE public.activity_type RENAME TO thread_type;
  END IF;

  -- Phase 5: Rename tables
  IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'activity' AND schemaname = 'public') THEN
    ALTER TABLE public.activity RENAME TO thread;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'activity_read' AND schemaname = 'public') THEN
    ALTER TABLE public.activity_read RENAME TO thread_read;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'activity_user_state' AND schemaname = 'public') THEN
    ALTER TABLE public.activity_user_state RENAME TO thread_user_state;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'activity_tag' AND schemaname = 'public') THEN
    ALTER TABLE public.activity_tag RENAME TO thread_tag;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'activity_exception' AND schemaname = 'public') THEN
    ALTER TABLE public.activity_exception RENAME TO thread_exception;
  END IF;

  -- Phase 6: Rename columns (check column exists before rename)
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'thread' AND column_name = 'links') THEN
    ALTER TABLE public.thread RENAME COLUMN links TO actions;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'note' AND column_name = 'activity_id') THEN
    ALTER TABLE public.note RENAME COLUMN activity_id TO thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'note' AND column_name = 'links') THEN
    ALTER TABLE public.note RENAME COLUMN links TO actions;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'thread_read' AND column_name = 'activity_id') THEN
    ALTER TABLE public.thread_read RENAME COLUMN activity_id TO thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'thread_user_state' AND column_name = 'activity_id') THEN
    ALTER TABLE public.thread_user_state RENAME COLUMN activity_id TO thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'thread_tag' AND column_name = 'activity_id') THEN
    ALTER TABLE public.thread_tag RENAME COLUMN activity_id TO thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'thread_exception' AND column_name = 'activity_id') THEN
    ALTER TABLE public.thread_exception RENAME COLUMN activity_id TO thread_id;
  END IF;

  -- Phase 7: Rename sequences
  IF EXISTS (SELECT 1 FROM pg_sequences WHERE sequencename = 'activity_tag_id_seq') THEN
    ALTER SEQUENCE public.activity_tag_id_seq RENAME TO thread_tag_id_seq;
  END IF;

  -- Phase 8: Rename constraints
  -- thread table constraints
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_pkey') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_pkey TO thread_pkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_priority_id_fkey') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_priority_id_fkey TO thread_priority_id_fkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_action_assignee') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_action_assignee TO thread_action_assignee;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_done_requires_action') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_done_requires_action TO thread_done_requires_action;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_no_complete_recurrence') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_no_complete_recurrence TO thread_no_complete_recurrence;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_recurrence_on_or_at') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_recurrence_on_or_at TO thread_recurrence_on_or_at;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_scheduled') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_scheduled TO thread_scheduled;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_single_schedule') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_single_schedule TO thread_single_schedule;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_title_required_when_not_draft') THEN
    ALTER TABLE public.thread RENAME CONSTRAINT activity_title_required_when_not_draft TO thread_title_required_when_not_draft;
  END IF;
  -- note table
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'note_activity_id_fkey') THEN
    ALTER TABLE public.note RENAME CONSTRAINT note_activity_id_fkey TO note_thread_id_fkey;
  END IF;
  -- thread_read
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_read_pkey') THEN
    ALTER TABLE public.thread_read RENAME CONSTRAINT activity_read_pkey TO thread_read_pkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_read_user_id_fkey') THEN
    ALTER TABLE public.thread_read RENAME CONSTRAINT activity_read_user_id_fkey TO thread_read_user_id_fkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_read_activity_id_fkey') THEN
    ALTER TABLE public.thread_read RENAME CONSTRAINT activity_read_activity_id_fkey TO thread_read_thread_id_fkey;
  END IF;
  -- thread_user_state
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_user_state_pkey') THEN
    ALTER TABLE public.thread_user_state RENAME CONSTRAINT activity_user_state_pkey TO thread_user_state_pkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_user_state_user_id_fkey') THEN
    ALTER TABLE public.thread_user_state RENAME CONSTRAINT activity_user_state_user_id_fkey TO thread_user_state_user_id_fkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_user_state_activity_id_fkey') THEN
    ALTER TABLE public.thread_user_state RENAME CONSTRAINT activity_user_state_activity_id_fkey TO thread_user_state_thread_id_fkey;
  END IF;
  -- thread_tag
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_tag_pkey') THEN
    ALTER TABLE public.thread_tag RENAME CONSTRAINT activity_tag_pkey TO thread_tag_pkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_tag_activity_id_fkey') THEN
    ALTER TABLE public.thread_tag RENAME CONSTRAINT activity_tag_activity_id_fkey TO thread_tag_thread_id_fkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_tag_actor_id_activity_id_occurrence_tag_id_key') THEN
    ALTER TABLE public.thread_tag RENAME CONSTRAINT activity_tag_actor_id_activity_id_occurrence_tag_id_key TO thread_tag_actor_id_thread_id_occurrence_tag_id_key;
  END IF;
  -- thread_exception
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_exception_pkey') THEN
    ALTER TABLE public.thread_exception RENAME CONSTRAINT activity_exception_pkey TO thread_exception_pkey;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'activity_exception_activity_id_fkey') THEN
    ALTER TABLE public.thread_exception RENAME CONSTRAINT activity_exception_activity_id_fkey TO thread_exception_thread_id_fkey;
  END IF;

  -- Phase 9: Rename indexes
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_priority_id') THEN
    ALTER INDEX idx_activity_priority_id RENAME TO idx_thread_priority_id;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_at') THEN
    ALTER INDEX idx_activity_at RENAME TO idx_thread_at;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_on') THEN
    ALTER INDEX idx_activity_on RENAME TO idx_thread_on;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_done_at') THEN
    ALTER INDEX idx_activity_done_at RENAME TO idx_thread_done_at;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_archived') THEN
    ALTER INDEX idx_activity_archived RENAME TO idx_thread_archived;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_priority_archived') THEN
    ALTER INDEX idx_activity_priority_archived RENAME TO idx_thread_priority_archived;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_source') THEN
    ALTER INDEX idx_activity_source RENAME TO idx_thread_source;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'activity_source_priority_unique') THEN
    ALTER INDEX activity_source_priority_unique RENAME TO thread_source_priority_unique;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_updated_at') THEN
    ALTER INDEX idx_activity_updated_at RENAME TO idx_thread_updated_at;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_created_at_priority') THEN
    ALTER INDEX idx_activity_created_at_priority RENAME TO idx_thread_created_at_priority;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_priority_archived_last_note') THEN
    ALTER INDEX idx_activity_priority_archived_last_note RENAME TO idx_thread_priority_archived_last_note;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_created_by') THEN
    ALTER INDEX idx_activity_created_by RENAME TO idx_thread_created_by;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'activity_embedding_idx') THEN
    ALTER INDEX activity_embedding_idx RENAME TO thread_embedding_idx;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'activity_exception_occurrence_unique') THEN
    ALTER INDEX activity_exception_occurrence_unique RENAME TO thread_exception_occurrence_unique;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_read_user_read') THEN
    ALTER INDEX idx_activity_read_user_read RENAME TO idx_thread_read_user_read;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_read_activity_id') THEN
    ALTER INDEX idx_activity_read_activity_id RENAME TO idx_thread_read_thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_user_state_activity_id') THEN
    ALTER INDEX idx_activity_user_state_activity_id RENAME TO idx_thread_user_state_thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_user_state_updated_at') THEN
    ALTER INDEX idx_activity_user_state_updated_at RENAME TO idx_thread_user_state_updated_at;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_activity_tag_activity_id') THEN
    ALTER INDEX idx_activity_tag_activity_id RENAME TO idx_thread_tag_thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_note_activity_id') THEN
    ALTER INDEX idx_note_activity_id RENAME TO idx_note_thread_id;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_note_activity_archived') THEN
    ALTER INDEX idx_note_activity_archived RENAME TO idx_note_thread_archived;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_note_author_activity') THEN
    ALTER INDEX idx_note_author_activity RENAME TO idx_note_author_thread;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'note_activity_key_unique') THEN
    ALTER INDEX note_activity_key_unique RENAME TO note_thread_key_unique;
  END IF;
END $$;
