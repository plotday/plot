import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Task 12 (link-removal sync): the v352 upgrade adds `links.revoked` and runs
/// a one-time cleanup that purges connector links — and their schedules —
/// whose owning twist_instance is already archived locally. Those orphans were
/// stranded by the old server-side hard-delete, which the seq cursor can't
/// observe. User-authored links (created_by is a user id, not a twist_instance)
/// must survive.
///
/// We build the current schema, drop the new `revoked` column, roll
/// `user_version` back to 351, seed an orphan connector link + its schedule and
/// a user-authored link, then reopen so `onUpgrade` runs the `from < 352` step.
void main() {
  test(
    'v352 upgrade clears connector links under archived instances + their schedules',
    () async {
      final raw = sqlite3.openInMemory();

      // 1. Build current schema (onCreate).
      final seed = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );

      final instanceId = Uuid.generate(); // archived connector instance
      final userId = Uuid.generate(); // a user (for the user-authored link)
      final orphanLinkId = Uuid.generate();
      final userLinkId = Uuid.generate();
      final schedId = Uuid.generate();

      await seed.into(seed.twistInstances).insert(
            TwistInstancesCompanion.insert(
              id: Value(instanceId),
              twistId: BigInt.from(1),
              twistEnvironment: 'prod',
              name: 'Linear',
              config: const {},
              archivedAt: Value(DateTime.now()), // archived
            ),
          );
      // connector orphan link (created_by = archived instance) + its schedule
      await seed.into(seed.links).insert(
            LinksCompanion.insert(
              id: Value(orphanLinkId),
              sourceCreatedAt: DateTime.now(),
              createdBy: Value(instanceId),
            ),
          );
      await seed.into(seed.schedules).insert(
            SchedulesCompanion.insert(
              id: Value(schedId),
              linkId: Value(orphanLinkId),
            ),
          );
      // user-authored link (created_by = a user id) — must survive
      await seed.into(seed.links).insert(
            LinksCompanion.insert(
              id: Value(userLinkId),
              sourceCreatedAt: DateTime.now(),
              createdBy: Value(userId),
            ),
          );
      await seed.close();

      // 2. Roll back to v351 (no `revoked` column yet).
      raw.execute('ALTER TABLE links DROP COLUMN revoked');
      raw.execute('PRAGMA user_version = 351');

      // 3. Reopen → onUpgrade runs the from<352 step.
      final upgraded = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      final orphanLinks = await (upgraded.select(upgraded.links)
            ..where((l) => l.createdBy.equals(instanceId.toBytes())))
          .get();
      final orphanScheds = await (upgraded.select(upgraded.schedules)
            ..where((s) => s.linkId.equals(orphanLinkId.toBytes())))
          .get();
      final userLinks = await (upgraded.select(upgraded.links)
            ..where((l) => l.createdBy.equals(userId.toBytes())))
          .get();

      expect(orphanLinks, isEmpty, reason: 'orphan connector link purged');
      expect(orphanScheds, isEmpty, reason: 'its schedule purged');
      expect(userLinks, hasLength(1), reason: 'user-authored link survives');

      await upgraded.close();
      raw.close();
    },
  );
}
