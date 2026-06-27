/// Locks in the focus-switch perf fix: on [PriorityBloc.setPriority] the
/// activity feed (the list the user is looking at) must emit BEFORE the
/// compose-box draft is resolved. Profiling showed the feed's section queries
/// were queued behind the chain-draft lookup, so the list waited on the
/// new-thread input's draft. The fix defers draft resolution until the feed's
/// first post-switch emit; this test asserts that emission order so a future
/// refactor can't silently reintroduce the contention.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/app_info.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

final _selfId = ActorId.fromString('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
final _focusId = Uuid.fromString('cccccccc-cccc-cccc-cccc-cccccccccccc');
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

Future<Priority> _insertFocus(Store store) async {
  await store.into(store.priorities).insert(
        PrioritiesCompanion(
          id: Value(_focusId),
          title: const Value('Marketing'),
          createdBy: Value(_selfId.value),
          isInbox: const Value(false),
        ),
      );
  return Priority.getOne(_focusId);
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

Future<void> _insertThreadInFocus(
  Store store, {
  required bool draft,
}) async {
  await store.into(store.threads).insert(
        ThreadsCompanion(
          id: Value(Uuid.generate()),
          priorityId: Value(_focusId),
          contacts: Value([_selfId.value]),
          groups: const Value([]),
          draft: Value(draft),
        ),
      );
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
  late Priority focus;
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
    focus = await _insertFocus(store);
    await Actor.get(self: true);
    Base.initForTesting(_selfId);

    // A real (non-draft) thread so the feed has content to emit, and a draft
    // filed in the focus so the chain-draft lookup has something to resolve.
    await _insertThreadInFocus(store, draft: false);
    await _insertThreadInFocus(store, draft: true);

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

  test(
      'setPriority emits the activity feed before resolving the compose draft',
      () async {
    // Construct in Everything mode anchored on the Inbox (no per-focus work on
    // construction). The initial draft therefore belongs to the Inbox, so the
    // draft transitioning to the focus is a real signal of the switch's draft
    // resolution — not a pre-existing match.
    final bloc = PriorityBloc(
      priority: inbox,
      nowBloc: nowBloc,
      localPreferences: localPreferences,
      everything: true,
    );
    addTearDown(bloc.close);
    await Future<void>.delayed(Duration.zero);

    var feedEmitOrder = -1;
    var draftEmitOrder = -1;
    var seq = 0;
    final sub = bloc.stream.listen((state) {
      seq++;
      // Feed emitted for the focus: the active tab now carries the focus's
      // items (activityFeedLoaded flips true with the focus context).
      if (feedEmitOrder < 0 &&
          state.activityFeedLoaded &&
          state.activeTabContext?.id == _focusId) {
        feedEmitOrder = seq;
      }
      // Draft resolved for the focus.
      if (draftEmitOrder < 0 && state.draft.priority.id == _focusId) {
        draftEmitOrder = seq;
      }
    });
    addTearDown(sub.cancel);

    // Act: switch into the focus.
    await bloc.setPriority(focus);

    // Let the feed subscription's Drift queries fire, the rebuild emit, and the
    // deferred draft microtask run.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(feedEmitOrder, greaterThan(0),
        reason: 'the feed should emit for the focus on switch');
    expect(draftEmitOrder, greaterThan(0),
        reason: 'the compose draft should resolve for the focus');
    expect(feedEmitOrder, lessThan(draftEmitOrder),
        reason: 'the feed must emit BEFORE the compose draft is resolved — '
            'the draft is deferred so its DB query no longer races the list');
  });
}
