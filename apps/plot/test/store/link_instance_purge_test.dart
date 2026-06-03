import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Task 14 (link-removal sync): when a twist_instance transitions to archived
/// (connector uninstall), the server hard-deletes its links — invisible to the
/// seq cursor — so the synced archived_at signal is the client's delete cue.
/// TwistInstancesBase.processPulledRows must purge that instance's connector
/// links and their schedules.
void main() {
  test(
    'archived twist_instance purges its connector links + schedules',
    () async {
      final raw = sqlite3.openInMemory();
      final store = Store.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(() async {
        await store.close();
        raw.close();
      });

      final instanceId = Uuid.generate();
      final linkId = Uuid.generate();
      final schedId = Uuid.generate();

      // seed a local (live) twist_instance, a link created_by it, + a schedule
      await store.into(store.twistInstances).insert(
            TwistInstancesCompanion.insert(
              id: Value(instanceId),
              twistId: BigInt.from(1),
              twistEnvironment: 'prod',
              name: 'Linear',
              config: const {},
            ),
          );
      await store.into(store.links).insert(
            LinksCompanion.insert(
              id: Value(linkId),
              sourceCreatedAt: DateTime.now(),
              createdBy: Value(instanceId),
            ),
          );
      await store.into(store.schedules).insert(
            SchedulesCompanion.insert(
              id: Value(schedId),
              linkId: Value(linkId),
            ),
          );

      // sync delivers the instance now archived
      final archived = TwistInstanceRow(
        updatedAt: DateTime.now(),
        id: instanceId,
        createdAt: DateTime.now(),
        archivedAt: DateTime.now(),
        twistId: BigInt.from(1),
        twistEnvironment: 'prod',
        draft: false,
        isSource: true,
        shared: false,
        name: 'Linear',
        handle: '',
        config: const {},
        defaultMentionCreated: false,
        defaultMentionMentioned: false,
        userConnected: false,
        isBuiltin: false,
        multipleInstances: false,
      );
      await TwistInstancesBase().processPulledRows(store, [archived]);

      expect(
        await (store.select(store.links)
              ..where((l) => l.createdBy.equals(instanceId.toBytes())))
            .get(),
        isEmpty,
      );
      expect(
        await (store.select(store.schedules)
              ..where((s) => s.linkId.equals(linkId.toBytes())))
            .get(),
        isEmpty,
      );
    },
  );
}
