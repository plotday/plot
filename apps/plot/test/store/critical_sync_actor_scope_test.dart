import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Locks in the fresh-device sign-in fix.
///
/// The 30s critical sync was dominated by the full `actor` pull: it paginates
/// the entire address book (every non-archived contact) AND sweeps all archived
/// actors, and `role`/`priority`/`_threadCritical` all `dependsOn: [actor]`, so
/// roles, priorities, and threads were blocked behind it. The full pull now runs
/// in `syncInitialDeferred`; the critical path instead pulls only the user's own
/// (self) actors via `_actorCritical` — enough for identity/ownership at first
/// paint, bounded to ~1–10 rows.
void main() {
  List<String> criticalNames() => SyncOrchestrator.instance
      .criticalPullLevels()
      .expand((level) => level)
      .map((e) => e.debugName)
      .toList();

  test('the full address-book pull is NOT on the critical path', () {
    expect(
      criticalNames(),
      isNot(contains('actor')),
      reason: 'the unbounded full `actor` pull must be deferred, not critical',
    );
  });

  test('the bounded self-actor pull IS on the critical path', () {
    expect(
      criticalNames(),
      contains('actor_critical'),
      reason: 'identity/ownership needs the user own actors at first paint',
    );
  });

  test('the rest of the critical set is intact', () {
    expect(
      criticalNames(),
      containsAll(<String>[
        'user_settings',
        'role',
        'priority',
        'priority_block',
        'thread_critical',
        'twist_instance_critical',
      ]),
    );
  });

  test('topological sort tolerates the dangling full-actor dependency', () {
    // role/priority/thread_critical declare dependsOn:[actor] (the full pull),
    // intentionally absent from the critical set. The sort must treat that
    // out-of-set dependency as satisfied instead of throwing.
    expect(
      () => SyncOrchestrator.instance.criticalPullLevels(),
      returnsNormally,
    );

    final levels = SyncOrchestrator.instance.criticalPullLevels();
    int levelOf(String name) =>
        levels.indexWhere((level) => level.any((e) => e.debugName == name));

    // Ordering among in-set dependencies is still honored.
    expect(
      levelOf('priority'),
      greaterThan(levelOf('role')),
      reason: 'priority dependsOn role',
    );
    expect(
      levelOf('thread_critical'),
      greaterThan(levelOf('priority')),
      reason: 'thread_critical dependsOn priority',
    );
  });
}
