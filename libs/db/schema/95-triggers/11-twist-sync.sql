-- Twist sync triggers for thread table
-- INSERT trigger: notifies twist when it creates a new thread (for thread.created callback)
-- UPDATE trigger: notifies twist when its thread is updated (for thread.updated callback)
CREATE TRIGGER twist_sync_thread_insert
  AFTER INSERT ON thread
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_thread();

CREATE TRIGGER twist_sync_thread_update
  AFTER UPDATE ON thread
  REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_thread();

-- Twist sync triggers for note table
CREATE TRIGGER twist_sync_note_insert
  AFTER INSERT ON note
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_note();

CREATE TRIGGER twist_sync_note_update
  AFTER UPDATE ON note
  REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_note();

-- Twist sync triggers for thread_tag table
CREATE TRIGGER twist_sync_thread_tag_insert
  AFTER INSERT ON thread_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_thread_tag();

CREATE TRIGGER twist_sync_thread_tag_update
  AFTER UPDATE ON thread_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_thread_tag();

-- Twist sync triggers for note_tag table
CREATE TRIGGER twist_sync_note_tag_insert
  AFTER INSERT ON note_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_note_tag();

CREATE TRIGGER twist_sync_note_tag_update
  AFTER UPDATE ON note_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_note_tag();

-- Twist sync triggers for link table
CREATE TRIGGER twist_sync_link_insert
  AFTER INSERT ON link
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_link();

CREATE TRIGGER twist_sync_link_update
  AFTER UPDATE ON link
  REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_link();
