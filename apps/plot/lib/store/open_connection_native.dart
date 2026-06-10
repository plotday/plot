import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart';

import 'zoned_read_pool.dart';

/// Number of dedicated read isolates. A focus switch fires a burst of
/// 10–30 SELECTs (feed heads, agenda streams, draft lookups, breadcrumb
/// priming) while sync pulls are committing writes; four readers absorb the
/// burst without queueing behind the writer or each other.
const _readPoolSize = 4;

/// Opens the Plot database on native platforms.
///
/// This intentionally bypasses `drift_flutter`'s `driftDatabase` (which the
/// web build still uses — see `open_connection_web.dart`) for two reasons:
///
///  1. **WAL.** The database historically ran in SQLite's default
///     rollback-journal mode, where every commit takes an exclusive lock and
///     a journal fsync. Sync pulls land mid-focus-switch, so reads queued
///     behind those commits. WAL makes commits cheap appends and lets
///     readers run concurrently with the writer. `journal_mode = WAL` is
///     persistent (it converts the file on first open) and a no-op
///     afterwards; `synchronous = NORMAL` is the recommended WAL pairing
///     (durability of the local cache is not critical — it can resync).
///  2. **Read pool.** Drift serialized every query of a switch burst on the
///     single background-isolate connection, which is what made heavy focus
///     switches take seconds. With WAL, SELECTs outside transactions can run
///     on [_readPoolSize] dedicated reader isolates instead. The pool wrapper
///     is [ZonedReadPoolExecutor] rather than drift's own
///     `MultiExecutor.withReadPool` because the latter loses the requester's
///     cancellation zone for queued selects (see zoned_read_pool.dart).
///
/// Path resolution (documents directory + `$name.sqlite`) matches
/// `drift_flutter` exactly so existing databases keep working. Like the
/// previous configuration (`tempDirectoryPath: () async => null`), this does
/// NOT set `sqlite3.tempDirectory` — resolving the temp-directory symbol can
/// crash on Android with native assets, and the system sqlite3 handles temp
/// files on its own.
QueryExecutor openPlotConnection(String name) {
  return DatabaseConnection.delayed(
    Future(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$name.sqlite');

      // The write connection opens first (drift runs migrations through it;
      // its setup performs the one-time WAL conversion). Readers open lazily
      // afterwards — ZonedReadPoolExecutor.ensureOpen awaits the writer
      // before the pool, so their WAL pragma is always a no-op.
      final write = NativeDatabase.createBackgroundConnection(
        file,
        setup: _setup,
      );
      final readers = <QueryExecutor>[
        for (var i = 0; i < _readPoolSize; i++)
          NativeDatabase.createBackgroundConnection(file, setup: _setup),
      ];

      return DatabaseConnection(
        ZonedReadPoolExecutor(reads: readers, write: write.executor),
        streamQueries: write.streamQueries,
        connectionData: write.connectionData,
      );
    }),
  );
}

/// Runs once per connection (writer + each reader). busy_timeout comes first
/// so the pragmas after it retry instead of failing if another connection
/// briefly holds the database; the rest are idempotent (WAL persists in the
/// file, NORMAL is a per-connection setting every connection should share).
void _setup(CommonDatabase db) {
  db.execute('PRAGMA busy_timeout = 5000;');
  db.execute('PRAGMA journal_mode = WAL;');
  db.execute('PRAGMA synchronous = NORMAL;');
}
