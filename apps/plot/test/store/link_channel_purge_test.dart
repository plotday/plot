import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:sqlite3/sqlite3.dart';

/// Task 15 (link-removal sync): when a channel transitions to disabled, the
/// server hard-deletes that channel's connector links — invisible to the seq
/// cursor — so the synced channel.enabled=false signal is the client's delete
/// cue. ChannelsBase.processPulledRows must purge that channel's connector
/// links (and their schedules) while leaving other channels' links intact.
void main() {
  test(
    "disabling a channel purges that channel's connector links + schedules",
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
      const channelId = 'chan-A';
      final channelRowId = BigInt.from(42);
      final linkId = Uuid.generate();
      final otherLinkId = Uuid.generate();
      final schedId = Uuid.generate();

      // seed: link on chan-A (purged) + link on chan-B (kept), both created_by
      // the instance, plus a schedule on the chan-A link.
      await store.into(store.links).insert(
            LinksCompanion.insert(
              id: Value(linkId),
              sourceCreatedAt: DateTime.now(),
              createdBy: Value(instanceId),
              channelId: const Value('chan-A'),
            ),
          );
      await store.into(store.links).insert(
            LinksCompanion.insert(
              id: Value(otherLinkId),
              sourceCreatedAt: DateTime.now(),
              createdBy: Value(instanceId),
              channelId: const Value('chan-B'),
            ),
          );
      await store.into(store.schedules).insert(
            SchedulesCompanion.insert(
              id: Value(schedId),
              linkId: Value(linkId),
            ),
          );
      // local channel currently enabled
      await store.into(store.channels).insert(
            ChannelsCompanion.insert(
              id: Value(channelRowId),
              twistInstanceId: instanceId,
              channelId: channelId,
              title: 'Channel A',
              enabled: const Value(true),
            ),
          );

      // sync delivers the same channel now disabled
      final disabled = ChannelRow(
        updatedAt: DateTime.now(),
        createdAt: DateTime.now(),
        id: channelRowId,
        twistInstanceId: instanceId,
        channelId: channelId,
        title: 'Channel A',
        enabled: false,
      );
      await ChannelsBase().processPulledRows(store, [disabled]);

      expect(
        await (store.select(store.links)
              ..where((l) => l.id.equals(linkId.toBytes())))
            .getSingleOrNull(),
        isNull,
      );
      expect(
        await (store.select(store.links)
              ..where((l) => l.id.equals(otherLinkId.toBytes())))
            .getSingleOrNull(),
        isNotNull,
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
