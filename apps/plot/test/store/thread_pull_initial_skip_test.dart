import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Regression guard for the recurring-backfill bug: `Thread.pullInitial()`
/// must be a complete no-op once the store is initialized. Its agenda/feed
/// pullTo calls have no caught-up short-circuit, so before this guard every
/// sync (including every broadcast-driven thread sync) pulled another page
/// of feed history + slice pulls + a redundant links pull.
///
/// Test-env property used here: no Base/auth singletons are registered, so
/// ANY attempted HTTP call throws. `completes` == "no network attempted".
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

  test('initialized store: pullInitial makes no network calls', () async {
    // thread_associations is the LAST initial-gated entity pullInitial
    // seeds, so its presence proves a prior initial run completed.
    await store.into(store.syncStates).insert(
          SyncStatesCompanion.insert(
            entity: 'thread_associations',
            pulledAt: Value(DateTime.now().toUtc().microsecondsSinceEpoch),
          ),
        );

    await expectLater(Thread.pullInitial(), completes);

    // The agenda/feed cursors were not created — the backfill did not run.
    final agenda = await (store.select(store.syncStates)
          ..where((r) => r.entity.equals('agenda')))
        .getSingleOrNull();
    final feed = await (store.select(store.syncStates)
          ..where((r) => r.entity.equals('activity-feed')))
        .getSingleOrNull();
    expect(agenda, isNull);
    expect(feed, isNull);
  });

  test('fresh store: pullInitial still runs (attempts network)', () async {
    // No sync states seeded — the guard must NOT skip. The first pull
    // attempts HTTP, which throws in the test env, proving the body ran.
    await expectLater(Thread.pullInitial(), throwsA(anything));
  });

  test('isEntityInitialized reflects lastHorizon or pulledAt', () async {
    expect(await store.isEntityInitialized('threads'), isFalse);
    await store.into(store.syncStates).insert(
          SyncStatesCompanion.insert(entity: 'threads', lastHorizon: const Value(42)),
        );
    expect(await store.isEntityInitialized('threads'), isTrue);
  });
}
