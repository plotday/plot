import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

void main() {
  late Store store;

  setUp(() {
    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);
  });

  tearDown(() async {
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  Future<void> insertPriority({
    required Uuid id,
    required String path,
    bool isInbox = false,
    DateTime? archivedAt,
  }) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(id),
            title: Value(path.split('.').last),
            createdBy: Value(Uuid.generate()),
            path: Value(Path(path)),
            order: const Value(Order(0)),
            isInbox: Value(isInbox),
            unread: const Value(false),
            role: const Value('member'),
            archivedAt: Value(archivedAt),
          ),
        );
  }

  test('resolves focus successfully with single active root', () async {
    final rootId = Uuid.generate();
    await insertPriority(id: rootId, path: 'inbox', isInbox: true);

    final focusId = Uuid.generate();
    await insertPriority(id: focusId, path: 'inbox.focus1');

    // Call the watermark update which internally invokes _firstLevelFocusFor.
    await store.updateNotificationWatermark(focusId);

    // Verify focus notificationClearedAt was updated.
    final updated = await (store.select(store.priorities)
          ..where((p) => p.id.equals(focusId.toBytes())))
        .getSingle();
    expect(updated.notificationClearedAt, isNotNull);
  });

  test('does not crash when an archived duplicate root exists', () async {
    final rootId = Uuid.generate();
    await insertPriority(id: rootId, path: 'inbox', isInbox: true);

    // Insert an archived root priority row
    final archivedRootId = Uuid.generate();
    await insertPriority(
      id: archivedRootId,
      path: 'inbox-old',
      isInbox: true,
      archivedAt: DateTime(2026, 1, 1),
    );

    final focusId = Uuid.generate();
    await insertPriority(id: focusId, path: 'inbox.focus1');

    // This would crash with 'Bad state: Too many elements' without the fix
    await store.updateNotificationWatermark(focusId);

    // Verify focus notificationClearedAt was updated.
    final updated = await (store.select(store.priorities)
          ..where((p) => p.id.equals(focusId.toBytes())))
        .getSingle();
    expect(updated.notificationClearedAt, isNotNull);
  });

  test('stamps the watermark on the focus itself, not other same-path rows',
      () async {
    // Flat/role model: focuses are leaves; the first-level focus for a
    // priority is the priority itself (path-independent), so the watermark is
    // stamped directly on the resolved focus and no other (archived) row is
    // touched.
    final rootId = Uuid.generate();
    await insertPriority(id: rootId, path: 'inbox', isInbox: true);

    // Insert an archived focus with same path
    final archivedFocusId = Uuid.generate();
    await insertPriority(
      id: archivedFocusId,
      path: 'inbox.focus1',
      archivedAt: DateTime(2026, 1, 1),
    );

    // Insert an active focus
    final activeFocusId = Uuid.generate();
    await insertPriority(id: activeFocusId, path: 'inbox.focus1');

    // Resolve watermark for the active focus directly.
    await store.updateNotificationWatermark(activeFocusId);

    final activeFocus = await (store.select(store.priorities)
          ..where((p) => p.id.equals(activeFocusId.toBytes())))
        .getSingle();
    expect(activeFocus.notificationClearedAt, isNotNull);

    final archivedFocus = await (store.select(store.priorities)
          ..where((p) => p.id.equals(archivedFocusId.toBytes())))
        .getSingle();
    expect(archivedFocus.notificationClearedAt, isNull);
  });
}
