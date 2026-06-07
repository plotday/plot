import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Proves the email-keyed contact reconciliation in
/// [ActorsBase.processPulledRows]: when a canonical server contact row
/// arrives with the SAME email but a DIFFERENT id than an optimistic temp
/// row the client inserted (via AddContact), the temp row is deleted so the
/// batch upsert leaves exactly one row keyed on the canonical id.
void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
    Actor.clearCache();
  });

  tearDown(() async {
    Actor.clearCache();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  test('processPulledRows removes a same-email optimistic temp row', () async {
    final tempId = Uuid.generate();
    final canonicalId = Uuid.generate();
    const email = 'dupe@example.test';

    // Optimistic temp row inserted by AddContact: temp id, pending sync.
    await store.into(store.actors).insert(
          ActorsCompanion.insert(
            id: ActorId(tempId),
            type: ActorType.contact,
            self: false,
            email: const Value(email),
            name: const Value('Temp'),
            pending: const Value(2),
          ),
        );

    // Canonical server row: DIFFERENT id, SAME email. fromJson requires
    // updated_at/created_at and the full server-derived shape.
    final now = DateTime.now().toUtc().toIso8601String();
    final canonical = ActorRow.fromJson({
      'id': canonicalId.toString(),
      'type': 'contact',
      'email': email,
      'name': 'Canonical',
      'self': false,
      'inviteable': true,
      'primary': true,
      'external_accounts': <dynamic>[],
      'updated_at': now,
      'created_at': now,
    });

    final base = ActorsBase();
    final processed = await base.processPulledRows(store, [canonical]);
    await store.batch(
      (b) => b.insertAll(
        store.actors,
        processed,
        mode: InsertMode.insertOrReplace,
      ),
    );

    final rows = await store.select(store.actors).get();
    final dupes = rows.where((r) => r.email == email).toList();
    expect(dupes.length, 1, reason: 'temp duplicate should be deleted');
    expect(dupes.single.id.toUuid().toString(), canonicalId.toString());
  });
}
