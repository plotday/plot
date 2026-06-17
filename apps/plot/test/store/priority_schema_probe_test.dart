import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Regression guard for the rebuild-on-every-launch bug.
///
/// `Store.beforeOpen` runs [Store.schemaProbes] to detect a stale on-disk
/// schema (web OPFS surviving "Clear site data"). Each probe selects columns
/// from a recently-changed table; if any column is missing the probe throws and
/// the DB is fully rebuilt.
///
/// v373 dropped `priorities.root`, but the probe kept selecting `root`. Against
/// a current schema (which correctly lacks `root`) the probe threw on EVERY
/// launch, so every v373 user wiped their local DB and ran a full re-sync each
/// start — slow launches, repeated "New user sync", and a downstream sign-out.
///
/// Every probe must therefore succeed against a freshly-created schema: a probe
/// may only reference columns that exist in the current Drift tables.
void main() {
  test('every schema probe succeeds against a freshly-created schema', () async {
    final raw = sqlite3.openInMemory();
    final store = Store.forTesting(
      NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
    );
    // Force onCreate so every current table/view/index exists.
    await store.customSelect('SELECT 1').get();

    for (final sql in Store.schemaProbes) {
      // Must not throw: a probe that references a non-existent column (e.g. a
      // dropped one) would fail here exactly as it does on every real launch.
      await store.customSelect(sql).get();
    }

    await store.close();
    raw.close();
  });
}
