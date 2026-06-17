import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:plot/store/store.dart';

/// Locks in the onboarding short-circuit fix in [Priority.hasNonRoot].
///
/// `activate_invited_user` seeds every new user TWO priorities: the root
/// "Everything" focus and a global, role-less "FYI" focus (a non-root
/// priority, `is_fyi = true`). [OnboardingBloc.start] skips onboarding when
/// `hasNonRoot()` is true — its "the user has used Plot before" signal — so
/// the seeded FYI focus MUST be excluded, or onboarding is suppressed for
/// every brand-new user.
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
    bool isInbox = false,
    bool isFyi = false,
    bool archived = false,
    String title = 'Focus',
  }) async {
    await store.into(store.priorities).insert(
          PrioritiesCompanion(
            id: Value(Uuid.generate()),
            title: Value(title),
            createdBy: Value(Uuid.generate()),
            path: Value(Path(title.toLowerCase())),
            order: const Value(Order(0)),
            isInbox: Value(isInbox),
            isFyi: Value(isFyi),
            unread: const Value(false),
            role: const Value('member'),
            archivedAt:
                archived ? Value(DateTime(2026, 1, 2)) : const Value.absent(),
          ),
        );
  }

  test('false for a fresh user (seeded Inbox + FYI focus only)', () async {
    await insertPriority(isInbox: true, title: 'Inbox');
    await insertPriority(isFyi: true, title: 'FYI');

    // Both seeded focuses (the role's auto-managed Inbox and the global FYI)
    // are auto-created at signup, so neither is evidence the user has used
    // Plot — onboarding must still run.
    expect(await Priority.hasNonRoot(), isFalse);
  });

  test('true once the user has a real (non-Inbox, non-FYI) focus', () async {
    await insertPriority(isInbox: true, title: 'Inbox');
    await insertPriority(isFyi: true, title: 'FYI');
    await insertPriority(title: 'Work');

    expect(await Priority.hasNonRoot(), isTrue);
  });

  test('an archived focus does not count', () async {
    await insertPriority(isInbox: true, title: 'Inbox');
    await insertPriority(title: 'Old', archived: true);

    expect(await Priority.hasNonRoot(), isFalse);
  });
}
