import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Regression test for the focus-icon migration gap: `priorities.icon` was
/// added to the Drift schema (commit ed0201941) without a migration step or a
/// `schemaVersion` bump. Databases already sitting at the prior version (347,
/// the version that shipped to `main` before the icon column existed) never
/// ran `onUpgrade`, so the column was never added and every priority query
/// crashed with "no such column: base.icon".
///
/// We reproduce a genuine pre-icon database by building the current schema
/// once, dropping `priorities.icon`, and pinning `user_version` back to 347.
/// Reopening the store must run the upgrade and re-add the column.
void main() {
  test('upgrading a pre-icon database re-adds priorities.icon', () async {
    final raw = sqlite3.openInMemory();

    // 1. Build the full current schema (runs onCreate, which includes icon).
    final seed = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    await seed.customSelect('SELECT 1').get();
    await seed.close();

    // 2. Roll the database back to the last release without the icon column.
    raw.execute('ALTER TABLE priorities DROP COLUMN icon');
    raw.execute('PRAGMA user_version = 347');
    expect(
      raw
          .select(
            "SELECT 1 FROM pragma_table_info('priorities') WHERE name = 'icon'",
          )
          .isEmpty,
      isTrue,
      reason: 'icon column should be absent before the upgrade runs',
    );

    // 3. Reopen — the upgrade must re-add the column so priority queries work.
    final upgraded = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    final rows =
        await upgraded.customSelect('SELECT icon FROM priorities').get();
    expect(rows, isEmpty);
    await upgraded.close();

    raw.close();
  });

  // Clients upgrading from before 347 run the `from < 347` rebuild, which
  // drops the retired respond_* columns. That rebuild copies the table via
  // INSERT...SELECT; declaring `icon` as a new column keeps it out of the
  // copy so the rebuild doesn't try to read a column the old table lacks and
  // fall back to a full reset. This proves the seeded data survives.
  test('upgrading from before the v347 rebuild keeps data and adds icon',
      () async {
    final raw = sqlite3.openInMemory();

    final seed = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    await seed.into(seed.priorities).insert(
          PrioritiesCompanion(
            id: Value(Uuid.generate()),
            title: const Value('Keep me'),
            createdBy: Value(Uuid.generate()),
            path: Value(Path('keep')),
            order: const Value(Order(0)),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
    await seed.close();

    // Roll back to a pre-347 shape: no icon, plus a stale respond_* column
    // the v347 rebuild is expected to drop.
    raw.execute('ALTER TABLE priorities DROP COLUMN icon');
    raw.execute('ALTER TABLE priorities ADD COLUMN respond_window TEXT');
    raw.execute('PRAGMA user_version = 346');

    // Reopen — the v347 rebuild + v348 add-column run without a full reset.
    final upgraded = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    final survivors =
        await upgraded.customSelect('SELECT icon FROM priorities').get();
    expect(
      survivors.length,
      1,
      reason: 'the seeded priority must survive the rebuild (no full reset)',
    );
    expect(
      raw
          .select(
            "SELECT 1 FROM pragma_table_info('priorities') "
            "WHERE name = 'respond_window'",
          )
          .isEmpty,
      isTrue,
      reason: 'the v347 rebuild should drop stale respond_* columns',
    );
    await upgraded.close();

    raw.close();
  });
}
