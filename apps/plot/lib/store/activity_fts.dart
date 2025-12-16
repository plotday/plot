part of 'store.dart';

/// FTS5 virtual table for full-text search on Activity title field.
/// This is a placeholder - the actual FTS5 table is created via custom SQL in migration.
@DataClassName('ActivityFtsRow')
class ActivityFts extends Table {
  // Store ID as reference to activities table
  BlobColumn get activityId => blob().map(const UuidConverter())();
  // Searchable text columns
  TextColumn get title => text()();

  @override
  String? get tableName => 'activity_fts';

  /// Creates the FTS5 virtual table for activity search and triggers to keep it in sync.
  static Future<void> createTable(DatabaseConnectionUser db) async {
    // Drop the regular table that Drift created and replace with FTS5 virtual table
    await db.customStatement('DROP TABLE IF EXISTS activity_fts');

    // Drop existing triggers if they exist
    await db.customStatement('DROP TRIGGER IF EXISTS activity_fts_insert');
    await db.customStatement('DROP TRIGGER IF EXISTS activity_fts_update');
    await db.customStatement('DROP TRIGGER IF EXISTS activity_fts_delete');

    // Create FTS5 virtual table with porter stemming for better search
    await db.customStatement('''
      CREATE VIRTUAL TABLE activity_fts USING fts5(
        activity_id UNINDEXED,
        title,
        tokenize = 'porter ascii'
      )
    ''');

    // Create trigger to populate FTS5 on activity insert
    await db.customStatement('''
      CREATE TRIGGER activity_fts_insert AFTER INSERT ON activities
      BEGIN
        INSERT INTO activity_fts(activity_id, title)
        VALUES (NEW.id, COALESCE(NEW.title, ''));
      END
    ''');

    // Create trigger to update FTS5 on activity update
    await db.customStatement('''
      CREATE TRIGGER activity_fts_update AFTER UPDATE ON activities
      BEGIN
        UPDATE activity_fts
        SET title = COALESCE(NEW.title, '')
        WHERE activity_id = NEW.id;
      END
    ''');

    // Create trigger to delete from FTS5 on activity delete
    await db.customStatement('''
      CREATE TRIGGER activity_fts_delete AFTER DELETE ON activities
      BEGIN
        DELETE FROM activity_fts WHERE activity_id = OLD.id;
      END
    ''');

    // Populate FTS5 table with existing activities
    await db.customStatement('''
      INSERT INTO activity_fts(activity_id, title)
      SELECT id, COALESCE(title, '')
      FROM activities
    ''');
  }
}
