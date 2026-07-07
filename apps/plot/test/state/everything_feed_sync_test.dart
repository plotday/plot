/// Bloc-level coverage for the Everything view's demand-driven global feed
/// sync in [PriorityBloc]:
///
///  1. Entering Everything via [PriorityBloc.setEverything] (the sidebar
///     toggle path — the priority page mirrors `NowBloc.everything` straight
///     into `setEverything`, which never runs `_loadPriority`) queues a
///     deferred GLOBAL activity-feed sync that fires on the flat head
///     stream's first emission.
///  2. Leaving Everything before the deferred sync fires clears it — no
///     stray global pull after toggling straight back out.
///  3. Deep scroll ([PriorityBloc.fetchMoreActivityFeedItems]) pulls more
///     global history when the local page comes back short (the real
///     local-exhaustion signal), without double-appending rows.
///
/// All syncs run against a seeded `noMore = true` sync state so
/// `Thread.pullActivityFeed` short-circuits before any network attempt (in
/// this test env any HTTP attempt hangs on the never-completed auth gate).
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/app_info.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _inboxId = Uuid.fromString('dddddddd-dddd-dddd-dddd-dddddddddddd');

Future<void> _insertActor(Store store, ActorId id) async {
  await store.into(store.actors).insert(
        ActorsCompanion(
          id: Value(id),
          type: const Value(ActorType.contact),
          name: const Value('Me'),
          email: const Value('me@test.example'),
          self: const Value(true),
          inviteable: const Value(true),
          primary: const Value(true),
        ),
      );
}

Future<Priority> _insertInbox(Store store) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(_inboxId),
          title: const Value('Inbox'),
          createdBy: Value(_selfId.value),
          isInbox: const Value(true),
        ),
      );
  return Priority.getOne(_inboxId);
}

/// Seeds `noMore = true` for the GLOBAL activity-feed cursor and the
/// Inbox-scoped one, so every `pullActivityFeed` in these tests
/// short-circuits locally (no network; see library doc).
Future<void> _seedNoMoreSyncStates(Store store) async {
  for (final entity in ['activity-feed', 'activity-feed:$_inboxId']) {
    await store.into(store.syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            noMore: const Value(true),
          ),
        );
  }
}

Future<void> _insertThreads(Store store, int count) async {
  final base = DateTime.utc(2026, 1, 1);
  for (var i = 0; i < count; i++) {
    await store.into(store.threads).insert(
          ThreadsCompanion(
            id: Value(Uuid.generate()),
            priorityId: Value(_inboxId),
            contacts: Value([_selfId.value]),
            groups: const Value([]),
            draft: const Value(false),
            createdAt: Value(base.add(Duration(minutes: i))),
          ),
        );
  }
}

/// Polls [condition] every 10ms until true or [timeout] elapses.
/// Returns whether the condition was met (so callers can assert with a
/// specific reason instead of an opaque timeout failure).
Future<bool> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    try {
      AppInfo.version = '0.0.0-test';
      AppInfo.buildNumber = '0';
      AppInfo.platform = 'test';
      AppInfo.versionString = 'v0.0.0-test (test build 0)';
    } catch (_) {/* already set when tests share a process */}
  });

  late Store store;
  late LocalPreferencesBloc localPreferences;
  late NowBloc nowBloc;
  late Priority inbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProfilePreferences.init();

    store = Store.forTesting(NativeDatabase.memory());
    Injector.appInstance.registerSingleton<Store>(() => store, override: true);

    Actor.clearCache();
    TwistInstance.clearCache();
    Channel.populateCache(const []);
    await _insertActor(store, _selfId);
    inbox = await _insertInbox(store);
    await Actor.get(self: true);
    Base.initForTesting(_selfId);
    await _seedNoMoreSyncStates(store);

    localPreferences = LocalPreferencesBloc();
    nowBloc = NowBloc();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await nowBloc.close();
    await localPreferences.close();
    Actor.clearCache();
    TwistInstance.clearCache();
    Base.removeForTesting();
    Injector.appInstance.removeByKey<Store>();
    await store.close();
  });

  PriorityBloc buildBloc({bool everything = false}) {
    final bloc = PriorityBloc(
      priority: inbox,
      nowBloc: nowBloc,
      localPreferences: localPreferences,
      everything: everything,
    );
    addTearDown(bloc.close);
    return bloc;
  }

  test('setEverything(true) queues a global feed sync that fires on the '
      'feed emission (before the 1500ms fallback timer)', () async {
    final bloc = buildBloc();

    // Focus mode: the feed loads without any GLOBAL sync.
    expect(await _pumpUntil(() => bloc.state.activityFeedLoaded), isTrue,
        reason: 'the sectioned feed should emit for the initial focus');
    expect(bloc.debugGlobalFeedSyncCount, 0,
        reason: 'a scoped focus must not trigger the global feed sync');

    // Enter Everything via the sidebar-toggle path (setEverything — NOT
    // _loadPriority / setPriority, which this path never runs).
    bloc.setEverything(true);

    // The deferred sync must fire off the flat head stream's first emission:
    // well before the 1500ms fallback timer, so a sub-1200ms deadline proves
    // the emission hook (not the timer) delivered it.
    expect(
      await _pumpUntil(
        () => bloc.debugGlobalFeedSyncCount >= 1,
        timeout: const Duration(milliseconds: 1200),
      ),
      isTrue,
      reason: 'entering Everything must trigger the GLOBAL feed sync via '
          'the feed-emission hook',
    );
    expect(bloc.debugGlobalFeedSyncCount, 1);
  });

  test('setEverything(false) before the deferred sync fires clears it — '
      'no stray global pull', () async {
    final bloc = buildBloc();
    expect(await _pumpUntil(() => bloc.state.activityFeedLoaded), isTrue);

    // Toggle in and straight back out before any stream emission or the
    // fallback timer can fire the armed sync.
    bloc.setEverything(true);
    bloc.setEverything(false);

    // Wait past both firing paths: the head-stream emission (ms) and the
    // 1500ms fallback timer armed on entry.
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    expect(bloc.debugGlobalFeedSyncCount, 0,
        reason: 'leaving Everything must clear the owed global sync');
  });

  test('deep scroll past a short local page pulls global history once and '
      'does not double-append rows', () async {
    // 55 threads: head page = 50 (saturated), leaving a 5-row short page
    // beyond it — the real local-exhaustion signal for the on-demand pull.
    await _insertThreads(store, 55);

    final bloc = buildBloc(everything: true);

    // Wait for the flat head to load AND the entry sync to complete (it
    // latches _activityFeedSyncNoMore = true from the seeded sync state).
    expect(
      await _pumpUntil(() =>
          bloc.state.activityFeedLoaded && bloc.debugGlobalFeedSyncCount >= 1),
      isTrue,
      reason: 'Everything construction should load the feed and run the '
          'entry sync',
    );
    final before = bloc.debugGlobalFeedSyncCount;

    // Re-arm the remote side (the entry sync latched noMore); the seeded
    // sync state still short-circuits the actual pull without network.
    bloc.debugActivityFeedSyncNoMore = false;

    await bloc.fetchMoreActivityFeedItems(50, 20);

    expect(bloc.debugGlobalFeedSyncCount, before + 1,
        reason: 'a short local page in Everything must trigger exactly one '
            'on-demand global pull (then stop: the pull re-latched noMore)');

    // No double-append: all 55 threads present, each exactly once.
    final items =
        bloc.state.activityFeedByTab[ActivityTab.unified]?.items ?? const [];
    final ids = items
        .whereType<AgendaThreadItem>()
        .map((item) => item.thread.id)
        .toList();
    expect(ids.length, 55,
        reason: 'head (50) + short page (5) should all be appended');
    expect(ids.toSet().length, ids.length,
        reason: 'the retry must not re-fetch rows already appended');
    expect(bloc.state.activityFeedDoneEnd, isTrue,
        reason: 'with the server exhausted and local pages drained, the '
            'feed must report done-end so the spinner stops');
  });
}
