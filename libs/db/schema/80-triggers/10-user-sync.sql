-- User sync triggers for activity table
CREATE TRIGGER user_sync_activity_insert
  AFTER INSERT ON activity
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_activity();

CREATE TRIGGER user_sync_activity_update
  AFTER UPDATE ON activity
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_activity();

-- User sync triggers for note table
CREATE TRIGGER user_sync_note_insert
  AFTER INSERT ON note
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_note();

CREATE TRIGGER user_sync_note_update
  AFTER UPDATE ON note
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_note();

-- User sync triggers for priority table
CREATE TRIGGER user_sync_priority_insert
  AFTER INSERT ON priority
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority();

CREATE TRIGGER user_sync_priority_update
  AFTER UPDATE ON priority
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority();

-- User sync triggers for session table
CREATE TRIGGER user_sync_session_insert
  AFTER INSERT ON session
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_session();

CREATE TRIGGER user_sync_session_update
  AFTER UPDATE ON session
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_session();

-- User sync triggers for priority_twist table
CREATE TRIGGER user_sync_priority_twist_insert
  AFTER INSERT ON priority_twist
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_twist();

CREATE TRIGGER user_sync_priority_twist_update
  AFTER UPDATE ON priority_twist
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_twist();

-- User sync triggers for activity_read table
CREATE TRIGGER user_sync_activity_read_insert
  AFTER INSERT ON activity_read
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_activity_read();

CREATE TRIGGER user_sync_activity_read_update
  AFTER UPDATE ON activity_read
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_activity_read();

-- User sync triggers for priority_contact table
CREATE TRIGGER user_sync_priority_contact_insert
  AFTER INSERT ON priority_contact
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_contact();

CREATE TRIGGER user_sync_priority_contact_update
  AFTER UPDATE ON priority_contact
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_contact();

-- User sync triggers for activity_tag table
CREATE TRIGGER user_sync_activity_tag_insert
  AFTER INSERT ON activity_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_activity_tag();

CREATE TRIGGER user_sync_activity_tag_update
  AFTER UPDATE ON activity_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_activity_tag();

-- User sync triggers for note_tag table
CREATE TRIGGER user_sync_note_tag_insert
  AFTER INSERT ON note_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_note_tag();

CREATE TRIGGER user_sync_note_tag_update
  AFTER UPDATE ON note_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_note_tag();

-- User sync triggers for contact table (for actor sync)
CREATE TRIGGER user_sync_contact_insert
  AFTER INSERT ON contact
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_contact();

CREATE TRIGGER user_sync_contact_update
  AFTER UPDATE ON contact
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_contact();
