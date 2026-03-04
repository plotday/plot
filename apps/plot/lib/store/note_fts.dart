part of 'store.dart';

/// FTS5 virtual table for full-text search on Note content field.
/// This is a placeholder - the actual FTS5 table is created via custom SQL in migration.
@DataClassName('NoteFtsRow')
class NoteFts extends Table {
  // Store IDs as reference to notes and threads tables
  BlobColumn get noteId => blob().map(const UuidConverter())();
  BlobColumn get threadId => blob().map(const UuidConverter())();
  // Searchable text columns
  TextColumn get content => text()();

  @override
  String? get tableName => 'note_fts';

  /// Creates the FTS5 virtual table for note search and triggers to keep it in sync.
  static Future<void> createTable(DatabaseConnectionUser db) async {
    // Drop the regular table that Drift created and replace with FTS5 virtual table
    await db.customStatement('DROP TABLE IF EXISTS note_fts');

    // Drop existing triggers if they exist
    await db.customStatement('DROP TRIGGER IF EXISTS note_fts_insert');
    await db.customStatement('DROP TRIGGER IF EXISTS note_fts_update');
    await db.customStatement('DROP TRIGGER IF EXISTS note_fts_delete');

    // Create FTS5 virtual table with porter stemming for better search
    await db.customStatement('''
      CREATE VIRTUAL TABLE note_fts USING fts5(
        note_id UNINDEXED,
        thread_id UNINDEXED,
        content,
        tokenize = 'porter ascii'
      )
    ''');

    // Create trigger to populate FTS5 on note insert
    await db.customStatement('''
      CREATE TRIGGER note_fts_insert AFTER INSERT ON notes
      BEGIN
        INSERT INTO note_fts(note_id, thread_id, content)
        VALUES (NEW.id, NEW.thread_id, COALESCE(NEW.content, ''));
      END
    ''');

    // Create trigger to update FTS5 on note update
    await db.customStatement('''
      CREATE TRIGGER note_fts_update AFTER UPDATE ON notes
      BEGIN
        UPDATE note_fts
        SET content = COALESCE(NEW.content, ''),
            thread_id = NEW.thread_id
        WHERE note_id = NEW.id;
      END
    ''');

    // Create trigger to delete from FTS5 on note delete
    await db.customStatement('''
      CREATE TRIGGER note_fts_delete AFTER DELETE ON notes
      BEGIN
        DELETE FROM note_fts WHERE note_id = OLD.id;
      END
    ''');

    // Populate FTS5 table with existing notes
    await db.customStatement('''
      INSERT INTO note_fts(note_id, thread_id, content)
      SELECT id, thread_id, COALESCE(content, '')
      FROM notes
    ''');
  }
}
