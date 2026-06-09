import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Task 13 (link-removal sync): a synced link row with `revoked=true` arrives
/// from user.link_redacted (a per-item connector removal with no bulk signal).
/// LinksBase.processPulledRows must hard-delete the local link AND its
/// schedules, and exclude the revoked row from the upsert batch.
void main() {
  test(
    'revoked link is hard-deleted with its schedules and excluded from upsert',
    () async {
      final raw = sqlite3.openInMemory();
      final store = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(() async {
        await store.close();
        raw.close();
      });

      final linkId = Uuid.generate();
      final schedId = Uuid.generate();

      // seed a local link + a schedule referencing it
      await store.into(store.links).insert(
            LinksCompanion.insert(
              id: Value(linkId),
              sourceCreatedAt: DateTime.now(),
            ),
          );
      await store.into(store.schedules).insert(
            SchedulesCompanion.insert(
              id: Value(schedId),
              linkId: Value(linkId),
            ),
          );

      final incoming = LinkRow(
        updatedAt: DateTime.now(),
        id: linkId,
        createdAt: DateTime.now(),
        sourceCreatedAt: DateTime.now(),
        priority: 0,
        noteScoped: false,
        revoked: true,
      );
      final processed = await LinksBase().processPulledRows(store, [incoming]);

      expect(processed, isEmpty); // revoked row excluded from upsert batch
      final link = await (store.select(store.links)
            ..where((l) => l.id.equals(linkId.toBytes())))
          .getSingleOrNull();
      expect(link, isNull); // local link hard-deleted
      final sched = await (store.select(store.schedules)
            ..where((s) => s.linkId.equals(linkId.toBytes())))
          .get();
      expect(sched, isEmpty); // its schedules hard-deleted
    },
  );
}
