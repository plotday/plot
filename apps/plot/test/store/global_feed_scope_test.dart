// apps/plot/test/store/global_feed_scope_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// The Everything view's on-demand pull uses the GLOBAL activity-feed
/// cursor: `pullActivityFeed(null)` must key sync state on entity
/// 'activity-feed' (no scope suffix) and must short-circuit WITHOUT any
/// network attempt once that cursor is marked noMore. (In the test env any
/// HTTP attempt throws, so `completes` proves the short-circuit.)
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

  test('ThreadsBase global feed scope maps to entity "activity-feed"', () {
    expect(ThreadsBase(syncName: 'activity-feed').fullName, 'activity-feed');
  });

  test('pullActivityFeed(null) respects global noMore without network', () async {
    await store.into(store.syncStates).insert(
          SyncStatesCompanion.insert(
            entity: 'activity-feed',
            noMore: const Value(true),
          ),
        );
    await expectLater(Thread.pullActivityFeed(null), completes);
  });
}
