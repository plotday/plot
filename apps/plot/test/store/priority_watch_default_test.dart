import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Regression guard for the sign-out-on-launch crash.
///
/// `Priority.watchDefault()` feeds `NowBloc`/`ScheduledDay` via `combineLatest`,
/// and `NowBloc.start()` is awaited during app startup. When the local DB has
/// no default focus yet — a brand-new user whose critical sync hasn't landed a
/// priority, or any moment the priorities table is transiently empty — the old
/// `.map((p) => p!)` threw "Null check operator used on a null value". That
/// error propagated through `NowBloc.start()` → "Failed to start app" →
/// `Base.signOut()`, bouncing the user to the sign-in screen on every launch.
///
/// `watchDefault()` must instead simply not emit until a default focus exists,
/// then emit it once one arrives.
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

  Future<void> insertInbox(String title) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(Uuid.generate()),
            title: Value(title),
            createdBy: Value(Uuid.generate()),
            path: Value(Path(title.toLowerCase())),
            order: const Value(Order(0)),
            isInbox: const Value(true),
            unread: const Value(false),
            role: const Value('member'),
          ),
        );
  }

  test('does not emit an error when there is no default focus', () async {
    final errors = <Object>[];
    final emitted = <Priority>[];

    final sub = Priority.watchDefault().listen(
      emitted.add,
      onError: errors.add,
    );

    // Let the empty-table emission (previously a null-check crash) flush.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      errors,
      isEmpty,
      reason: 'an empty priorities table must not surface a stream error',
    );
    expect(emitted, isEmpty, reason: 'nothing to emit until a default exists');

    await sub.cancel();
  });

  test('emits the default focus once one exists', () async {
    final emitted = <Priority>[];
    final first = Completer<Priority>();

    final sub = Priority.watchDefault().listen((p) {
      emitted.add(p);
      if (!first.isCompleted) first.complete(p);
    });

    await insertInbox('Inbox');

    final value = await first.future.timeout(const Duration(seconds: 2));
    expect(value.title, 'Inbox');

    await sub.cancel();
  });
}
