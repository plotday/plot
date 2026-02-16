-- Twist sync triggers for activity table
-- INSERT trigger: notifies twist when it creates a new activity (for activity.created callback)
-- UPDATE trigger: notifies twist when its activity is updated (for activity.updated callback)
CREATE TRIGGER twist_sync_activity_insert
  AFTER INSERT ON activity
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_activity();

CREATE TRIGGER twist_sync_activity_update
  AFTER UPDATE ON activity
  REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_activity();

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

-- Twist sync triggers for activity_tag table
CREATE TRIGGER twist_sync_activity_tag_insert
  AFTER INSERT ON activity_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_activity_tag();

CREATE TRIGGER twist_sync_activity_tag_update
  AFTER UPDATE ON activity_tag
  REFERENCING NEW TABLE AS new_table
  FOR EACH STATEMENT
  EXECUTE FUNCTION sync_twist_for_activity_tag();

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
