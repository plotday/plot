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

-- User sync triggers for twist_instance table
CREATE TRIGGER user_sync_twist_instance_insert
  AFTER INSERT ON twist_instance
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_twist_instance();

CREATE TRIGGER user_sync_twist_instance_update
  AFTER UPDATE ON twist_instance
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_twist_instance();

-- User sync triggers for thread_priority table
CREATE TRIGGER user_sync_thread_priority_insert
  AFTER INSERT ON thread_priority
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_priority();

CREATE TRIGGER user_sync_thread_priority_update
  AFTER UPDATE ON thread_priority
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_priority();

CREATE TRIGGER user_sync_thread_priority_delete
  AFTER DELETE ON thread_priority
  REFERENCING OLD TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_priority();

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

-- User sync triggers for thread_state table
CREATE TRIGGER user_sync_thread_state_insert
  AFTER INSERT ON thread_state
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_state();

CREATE TRIGGER user_sync_thread_state_update
  AFTER UPDATE ON thread_state
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_thread_state();

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

-- User sync triggers for channel table
CREATE TRIGGER user_sync_channel_insert
  AFTER INSERT ON channel
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_channel();

CREATE TRIGGER user_sync_channel_update
  AFTER UPDATE ON channel
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_channel();

-- User sync triggers for twist_instance_connection table
CREATE TRIGGER user_sync_twist_instance_connection_insert
  AFTER INSERT ON twist_instance_connection
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_twist_instance_connection();

CREATE TRIGGER user_sync_twist_instance_connection_update
  AFTER UPDATE ON twist_instance_connection
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_twist_instance_connection();

CREATE TRIGGER user_sync_twist_instance_connection_delete
  AFTER DELETE ON twist_instance_connection
  REFERENCING OLD TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_twist_instance_connection();

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

-- User sync triggers for team_user table
CREATE TRIGGER user_sync_team_user_insert
  AFTER INSERT ON team_user
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_team_user();

CREATE TRIGGER user_sync_team_user_update
  AFTER UPDATE ON team_user
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_team_user();

-- User sync triggers for group table
CREATE TRIGGER user_sync_group_insert
  AFTER INSERT ON "group"
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_group();

CREATE TRIGGER user_sync_group_update
  AFTER UPDATE ON "group"
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_user_for_group();
