-- Phase 9: Cleanup old sync system
-- This file drops all old triggers and functions from the previous sync implementation

-- Drop old triggers (15 total)
DROP TRIGGER IF EXISTS activity_insert_api_call ON activity;
DROP TRIGGER IF EXISTS activity_update_api_call ON activity;
DROP TRIGGER IF EXISTS note_insert_api_call ON note;
DROP TRIGGER IF EXISTS note_update_api_call ON note;
DROP TRIGGER IF EXISTS priority_insert_api_call ON priority;
DROP TRIGGER IF EXISTS priority_update_api_call ON priority;
DROP TRIGGER IF EXISTS session_insert_api_call ON session;
DROP TRIGGER IF EXISTS session_update_api_call ON session;
DROP TRIGGER IF EXISTS activity_read_insert_api_call ON activity_read;
DROP TRIGGER IF EXISTS activity_read_update_api_call ON activity_read;
DROP TRIGGER IF EXISTS priority_twist_insert_api_call ON priority_twist;
DROP TRIGGER IF EXISTS priority_twist_update_api_call ON priority_twist;
DROP TRIGGER IF EXISTS notify_api_for_activity_tag_change ON activity_tag;
DROP TRIGGER IF EXISTS notify_api_for_note_tag_change ON note_tag;
DROP TRIGGER IF EXISTS broadcast_priority_contact_insert ON priority_contact;

-- Drop old functions (11 total)
DROP FUNCTION IF EXISTS notify_internal_api_for_activity();
DROP FUNCTION IF EXISTS notify_internal_api_for_note();
DROP FUNCTION IF EXISTS notify_internal_api_for_priority();
DROP FUNCTION IF EXISTS notify_internal_api_for_session();
DROP FUNCTION IF EXISTS notify_internal_api_for_activity_read();
DROP FUNCTION IF EXISTS notify_internal_api_for_priority_twist();
DROP FUNCTION IF EXISTS notify_for_activity_tag_change();
DROP FUNCTION IF EXISTS notify_for_note_tag_change();
DROP FUNCTION IF EXISTS notify_internal_api_for_activity_from_record(record, record, bigint);
DROP FUNCTION IF EXISTS notify_internal_api_for_note_from_record(record, record, bigint);
DROP FUNCTION IF EXISTS broadcast_priority_contact_sync();
