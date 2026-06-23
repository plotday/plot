import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';

import 'package:plot/state/priority.dart' show resolvePriorityWithFallback;
import 'package:plot/store/store.dart';

/// Locks in graceful handling for priority deep links that don't resolve
/// locally (e.g. an update-email link to a focus the device hasn't synced).
/// [resolvePriorityWithFallback] must never throw: it falls back to the
/// user's default focus and reports `fellBack` so the caller can surface a
/// toast — instead of the old behaviour where `PriorityBlocProvider`'s
/// switch path let `Priority.getOne`'s "Priority not found" StateError escape
/// uncaught and the feed spun forever.
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

  Future<void> insertPriority(
    Uuid id, {
    String title = 'Focus',
    bool isInbox = false,
    DateTime? createdAt,
  }) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(id),
            title: Value(title),
            createdBy: Value(Uuid.generate()),
            isInbox: Value(isInbox),
            createdAt:
                createdAt == null ? const Value.absent() : Value(createdAt),
            order: const Value(Order(0)),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
  }

  test('resolves the requested priority when it exists, no fallback', () async {
    final id = Uuid.generate();
    await insertPriority(id, title: 'Requested');

    final result = await resolvePriorityWithFallback(id);

    expect(result.priority?.id, id);
    expect(result.priority?.title, 'Requested');
    expect(result.fellBack, isFalse);
  });

  test('falls back to the default focus when the requested id is missing',
      () async {
    final defaultId = Uuid.generate();
    await insertPriority(defaultId, title: 'Home', isInbox: true);

    final missingId = Uuid.generate();
    final result = await resolvePriorityWithFallback(missingId);

    expect(result.priority?.id, defaultId,
        reason: 'a missing priority falls back to the default focus');
    expect(result.fellBack, isTrue);
  });

  test('returns null (still fellBack) when nothing can be loaded', () async {
    // Empty store: no requested priority and no default to fall back to.
    final result = await resolvePriorityWithFallback(Uuid.generate());

    expect(result.priority, isNull);
    expect(result.fellBack, isTrue);
  });
}
