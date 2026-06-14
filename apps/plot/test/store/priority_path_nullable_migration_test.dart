import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Plan 6 (client path-independence): the v369 upgrade makes `priorities.path`
/// nullable via `m.alterTable(TableMigration(priorities))`. `TableMigration`
/// with no `columnTransformer`/`newColumns` rebuilds the table from the current
/// Drift schema and copies every current column verbatim from the old table
/// (`INSERT INTO tmp (...cols...) SELECT ...cols... FROM priorities`). Because
/// v369 only flips `path`'s nullability — it adds NO columns — every current
/// column already exists in a genuine v368 table, so the copy preserves all
/// rows while the new table declares `path` as nullable.
///
/// This is the high-stakes regression guard: a *genuine* v368 → v369 upgrade
/// must NOT lose priority rows. We reconstruct a real v368 `priorities` table
/// (identical to the current schema except `path` is `NOT NULL`, and including
/// the v368-added `role_id`/`is_inbox` columns), seed rows with a non-null
/// `path`, pin `user_version = 368` so the upgrade runs from 368 → 369 and the
/// only `if (from < N)` branch that fires is `from < 369`, then reopen and
/// assert the rows survive and `path` is now nullable.
void main() {
  // The full v368 `priorities` DDL: byte-for-byte the current schema's CREATE
  // TABLE (dumped from a freshly-created store) with the single v368 difference
  // — `"path" TEXT NOT NULL` instead of the v369 `"path" TEXT NULL`. Building
  // the table at this exact shape is what makes the test a true v368→v369
  // exercise: if we just rolled `user_version` back on the current (already
  // nullable) table, the nullability flip would be a no-op and we'd prove
  // nothing.
  const v368PrioritiesDdl = '''
CREATE TABLE "priorities" (
  "updated_at" TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
  "pending" INTEGER NULL,
  "id" BLOB NOT NULL,
  "created_at" TEXT NOT NULL DEFAULT (CURRENT_TIMESTAMP),
  "archived_at" TEXT NULL,
  "title" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "created_by" BLOB NOT NULL,
  "top_order" REAL NULL,
  "order" REAL NOT NULL,
  "pomodoro" INTEGER NULL DEFAULT 1500,
  "color" INTEGER NULL,
  "icon" TEXT NULL,
  "description" TEXT NULL,
  "key" TEXT NULL,
  "root" INTEGER NOT NULL DEFAULT 0 CHECK ("root" IN (0, 1)),
  "unread" INTEGER NOT NULL DEFAULT 0 CHECK ("unread" IN (0, 1)),
  "role" TEXT NOT NULL DEFAULT 'member',
  "attention_window" TEXT NULL,
  "see_within" TEXT NULL,
  "attention_window_set" INTEGER NOT NULL DEFAULT 0 CHECK ("attention_window_set" IN (0, 1)),
  "see_within_set" INTEGER NOT NULL DEFAULT 0 CHECK ("see_within_set" IN (0, 1)),
  "early_notifications_enabled" INTEGER NULL CHECK ("early_notifications_enabled" IN (0, 1)),
  "notify_window" TEXT NULL,
  "early_notifications_enabled_set" INTEGER NOT NULL DEFAULT 0 CHECK ("early_notifications_enabled_set" IN (0, 1)),
  "notify_window_set" INTEGER NOT NULL DEFAULT 0 CHECK ("notify_window_set" IN (0, 1)),
  "config" TEXT NULL,
  "notification_cleared_at" TEXT NULL,
  "role_id" BLOB NULL,
  "is_inbox" INTEGER NOT NULL DEFAULT 0 CHECK ("is_inbox" IN (0, 1)),
  PRIMARY KEY ("id")
)''';

  test(
    'v368 -> v369 upgrade preserves priority rows and makes path nullable',
    () async {
      final raw = sqlite3.openInMemory();

      // 1. Build the full current schema (onCreate) so every OTHER table/view/
      //    index Drift expects exists. This creates `priorities` at the v369
      //    (nullable-path) shape.
      final seed = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await seed.customSelect('SELECT 1').get();
      await seed.close();

      // 2. Replace `priorities` with a genuine v368-shaped table (path NOT
      //    NULL). The current table is empty after onCreate, so dropping it
      //    loses nothing. Drop the path index too — it gets recreated by the
      //    TableMigration rebuild and the end-of-upgrade index pass.
      raw.execute('DROP INDEX IF EXISTS idx_priorities_path');
      raw.execute('DROP TABLE priorities');
      raw.execute(v368PrioritiesDdl);

      // 3. Seed two priorities with NON-NULL paths plus the v368-era
      //    role_id / is_inbox columns set, so we can confirm those round-trip
      //    through the rebuild unchanged.
      final keepId = Uuid.generate();
      final inboxId = Uuid.generate();
      final creator = Uuid.generate();
      final roleId = Uuid.generate();

      void insertV368(Uuid id, String title, String path, bool isInbox) {
        raw.execute(
          'INSERT INTO priorities '
          '(id, title, path, created_by, "order", role_id, is_inbox) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [
            id.toBytes(),
            title,
            path,
            creator.toBytes(),
            1.0,
            roleId.toBytes(),
            isInbox ? 1 : 0,
          ],
        );
      }

      insertV368(keepId, 'Keep me', 'a', false);
      insertV368(inboxId, 'Inbox', 'a.inbox', true);

      // Sanity: the seeded table really is v368 (path NOT NULL) and has 2 rows.
      final pathColBefore = raw.select(
        "SELECT \"notnull\" FROM pragma_table_info('priorities') "
        "WHERE name = 'path'",
      );
      expect(
        pathColBefore.first['notnull'],
        1,
        reason: 'precondition: v368 path must be NOT NULL',
      );
      expect(
        raw.select('SELECT COUNT(*) AS c FROM priorities').first['c'],
        2,
        reason: 'precondition: two seeded rows',
      );

      // 4. Pin to v368 so the upgrade runs from 368 → 369. The incremental
      //    migration is a chain of `if (from < N)` guards; with from == 368 the
      //    only branch that fires is `from < 369` (the path-nullability step) —
      //    every earlier branch is skipped. (NB: a freshly-created store is
      //    already at the current version, so pinning to 369 here would make
      //    from == to and onUpgrade would never run at all.)
      raw.execute('PRAGMA user_version = 368');

      // 5. Reopen → onUpgrade runs the v369 step:
      //    `m.alterTable(TableMigration(priorities))`.
      final upgraded = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );

      // The seeded rows must survive the rebuild — this is the data-loss guard.
      final rows = await upgraded.customSelect(
        'SELECT hex(id) AS id, title, path, hex(role_id) AS role_id, is_inbox '
        'FROM priorities ORDER BY path',
      ).get();
      expect(
        rows.length,
        2,
        reason: 'both seeded priorities must survive the v369 rebuild',
      );

      final keep = rows.firstWhere((r) => r.read<String>('title') == 'Keep me');
      expect(keep.read<String>('path'), 'a', reason: 'path value preserved');
      expect(
        keep.read<int>('is_inbox'),
        0,
        reason: 'is_inbox preserved (false)',
      );
      expect(
        keep.read<String?>('role_id'),
        isNotNull,
        reason: 'role_id preserved through rebuild',
      );

      final inbox = rows.firstWhere((r) => r.read<String>('title') == 'Inbox');
      expect(inbox.read<String>('path'), 'a.inbox');
      expect(
        inbox.read<int>('is_inbox'),
        1,
        reason: 'is_inbox preserved (true)',
      );

      // The rebuilt table must now declare `path` as nullable...
      final pathColAfter = raw.select(
        "SELECT \"notnull\" FROM pragma_table_info('priorities') "
        "WHERE name = 'path'",
      );
      expect(
        pathColAfter.first['notnull'],
        0,
        reason: 'v369 must make path nullable',
      );

      // ...and a NULL-path insert (a locally-created, not-yet-synced focus)
      // must now succeed — the whole point of the nullability change.
      await upgraded.customStatement(
        'INSERT INTO priorities (id, title, created_by, "order") '
        'VALUES (?, ?, ?, ?)',
        [Uuid.generate().toBytes(), 'Local draft', creator.toBytes(), 2.0],
      );
      final afterNullInsert = await upgraded.customSelect(
        'SELECT COUNT(*) AS c FROM priorities WHERE path IS NULL',
      ).getSingle();
      expect(
        afterNullInsert.read<int>('c'),
        1,
        reason: 'a NULL-path priority can be inserted after v369',
      );

      await upgraded.close();
      raw.close();
    },
  );
}
