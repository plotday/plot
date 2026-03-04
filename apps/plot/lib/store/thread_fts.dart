part of 'store.dart';

/// FTS5 virtual table for full-text search on Thread title field.
/// This is a placeholder - the actual FTS5 table is created via custom SQL in migration.
@DataClassName('ThreadFtsRow')
class ThreadFts extends Table {
  // Store ID as reference to threads table
  BlobColumn get threadId => blob().map(const UuidConverter())();
  // Searchable text columns
  TextColumn get title => text()();

  @override
  String? get tableName => 'thread_fts';

  /// Creates the FTS5 virtual table for thread search and triggers to keep it in sync.
  static Future<void> createTable(DatabaseConnectionUser db) async {
    // Drop the regular table that Drift created and replace with FTS5 virtual table
    await db.customStatement('DROP TABLE IF EXISTS thread_fts');

    // Drop existing triggers if they exist
    await db.customStatement('DROP TRIGGER IF EXISTS thread_fts_insert');
    await db.customStatement('DROP TRIGGER IF EXISTS thread_fts_update');
    await db.customStatement('DROP TRIGGER IF EXISTS thread_fts_delete');

    // Create FTS5 virtual table with porter stemming for better search
    await db.customStatement('''
      CREATE VIRTUAL TABLE thread_fts USING fts5(
        thread_id UNINDEXED,
        title,
        tokenize = 'porter ascii'
      )
    ''');

    // Create trigger to populate FTS5 on thread insert
    await db.customStatement('''
      CREATE TRIGGER thread_fts_insert AFTER INSERT ON threads
      BEGIN
        INSERT INTO thread_fts(thread_id, title)
        VALUES (NEW.id, COALESCE(NEW.title, ''));
      END
    ''');

    // Create trigger to update FTS5 on thread update
    await db.customStatement('''
      CREATE TRIGGER thread_fts_update AFTER UPDATE ON threads
      BEGIN
        UPDATE thread_fts
        SET title = COALESCE(NEW.title, '')
        WHERE thread_id = NEW.id;
      END
    ''');

    // Create trigger to delete from FTS5 on thread delete
    await db.customStatement('''
      CREATE TRIGGER thread_fts_delete AFTER DELETE ON threads
      BEGIN
        DELETE FROM thread_fts WHERE thread_id = OLD.id;
      END
    ''');

    // Populate FTS5 table with existing threads
    await db.customStatement('''
      INSERT INTO thread_fts(thread_id, title)
      SELECT id, COALESCE(title, '')
      FROM threads
    ''');
  }
}
