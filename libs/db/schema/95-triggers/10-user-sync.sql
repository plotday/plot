-- User sync triggers for thread table
CREATE TRIGGER user_sync_thread_insert
  AFTER INSERT ON thread
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread();

CREATE TRIGGER user_sync_thread_update
  AFTER UPDATE ON thread
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread();

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

-- User sync triggers for thread_read table
CREATE TRIGGER user_sync_thread_read_insert
  AFTER INSERT ON thread_read
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_read();

CREATE TRIGGER user_sync_thread_read_update
  AFTER UPDATE ON thread_read
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_read();

-- User sync triggers for thread_unread table
CREATE TRIGGER user_sync_thread_unread_insert
  AFTER INSERT ON thread_unread
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_unread();

CREATE TRIGGER user_sync_thread_unread_update
  AFTER UPDATE ON thread_unread
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_unread();

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

-- User sync triggers for thread_tag table
CREATE TRIGGER user_sync_thread_tag_insert
  AFTER INSERT ON thread_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_tag();

CREATE TRIGGER user_sync_thread_tag_update
  AFTER UPDATE ON thread_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_tag();

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

-- User sync triggers for priority_user table (for priority_member sync)
CREATE TRIGGER user_sync_priority_user_insert
  AFTER INSERT ON priority_user
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_user();

CREATE TRIGGER user_sync_priority_user_update
  AFTER UPDATE ON priority_user
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_user();

-- User sync triggers for source_channel table
CREATE TRIGGER user_sync_source_channel_insert
  AFTER INSERT ON source_channel
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_source_channel();

CREATE TRIGGER user_sync_source_channel_update
  AFTER UPDATE ON source_channel
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_source_channel();

-- User sync triggers for priority_twist_connection table
CREATE TRIGGER user_sync_priority_twist_connection_insert
  AFTER INSERT ON priority_twist_connection
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_twist_connection();

CREATE TRIGGER user_sync_priority_twist_connection_delete
  AFTER DELETE ON priority_twist_connection
  REFERENCING OLD TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_priority_twist_connection();

-- User sync triggers for link table
CREATE TRIGGER user_sync_link_insert
  AFTER INSERT ON link
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_link();

CREATE TRIGGER user_sync_link_update
  AFTER UPDATE ON link
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_link();

-- User sync triggers for schedule table
CREATE TRIGGER user_sync_schedule_insert
  AFTER INSERT ON schedule
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_schedule();

CREATE TRIGGER user_sync_schedule_update
  AFTER UPDATE ON schedule
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_schedule();
