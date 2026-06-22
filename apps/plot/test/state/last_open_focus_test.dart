import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:injector/injector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plot/state/last_open_focus.dart';
import 'package:plot/state/now.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/profile_preferences.dart';

// Build a DB-free Priority. Copied verbatim from the helper in
// test/state/everything_entry_test.dart (lines 12-31). If that helper drifts,
// re-copy it.
Priority _focus(String title, {bool isInbox = false, RoleId? roleId}) =>
    Priority.fromStore(
      PriorityRow(
        id: Uuid.generate(),
        createdBy: Uuid.generate(),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        title: title,
        path: Path(title.toLowerCase()),
        order: const Order(0),
        unread: false,
        role: 'member',
        roleId: roleId,
        isInbox: isInbox,
        isFyi: false,
        attentionWindowSet: false,
        seeWithinSet: false,
        earlyNotificationsEnabledSet: false,
        notifyWindowSet: false,
      ),
      draft: true,
    );

NowLoaded _seed({
  required Priority defaultPriority,
  List<Priority> priorities = const [],
  Priority? context,
  PriorityId? lastOpenFocusId,
  Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority = const {},
  Session? session,
}) =>
    NowLoaded(
      defaultPriority: defaultPriority,
      day: ScheduledDay.empty(),
      priorities: priorities,
      context: context,
      lastOpenFocusId: lastOpenFocusId,
      priorityBlocksByPriority: priorityBlocksByPriority,
      session: session,
    );

void main() {
  group('recordLastOpenFocus / loadLastOpenFocusId', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
    });

    test('record then load round-trips the picked focus id', () async {
      final work = _focus('Work');
      await recordLastOpenFocus(work);
      expect(loadLastOpenFocusId(), work.id);
    });

    test('a deliberately chosen Inbox is recorded too', () async {
      final inbox = _focus('Inbox', isInbox: true);
      await recordLastOpenFocus(inbox);
      expect(loadLastOpenFocusId(), inbox.id);
    });

    test('recording the Everything feed (null) leaves the stored focus', () async {
      final work = _focus('Work');
      await recordLastOpenFocus(work);
      await recordLastOpenFocus(null);
      expect(loadLastOpenFocusId(), work.id);
    });

    test('load returns null when nothing has been recorded', () {
      expect(loadLastOpenFocusId(), isNull);
    });

    test('load returns null when the stored value is malformed', () async {
      await ProfilePreferences.instance
          .setString(kLastOpenFocusKey, 'not-a-uuid');
      expect(loadLastOpenFocusId(), isNull);
    });
  });

  group('NowLoaded.priority — last open focus rung', () {
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    test('returns the last open focus when nothing above it applies', () {
      final inbox = _focus('Inbox', isInbox: true);
      final work = _focus('Work');
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox, work],
        lastOpenFocusId: work.id,
      );
      expect(state.priority.id, work.id);
    });

    test('falls back to the default when the last open focus is gone', () {
      final inbox = _focus('Inbox', isInbox: true);
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox], // the recorded focus was archived/deleted
        lastOpenFocusId: Uuid.generate(),
      );
      expect(state.priority.id, inbox.id);
    });

    test('falls back to the default when no last open focus is stored', () {
      final inbox = _focus('Inbox', isInbox: true);
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox],
        lastOpenFocusId: null,
      );
      expect(state.priority.id, inbox.id);
    });

    test('an explicit context outranks the last open focus', () {
      final inbox = _focus('Inbox', isInbox: true);
      final work = _focus('Work');
      final reading = _focus('Reading');
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox, work, reading],
        context: reading,
        lastOpenFocusId: work.id,
      );
      expect(state.priority.id, reading.id);
    });

    test('an active focus block outranks the last open focus', () {
      Time.setFrozenTime(DateTime(2026, 5, 1, 9, 30));
      addTearDown(Time.unfreeze);
      final inbox = _focus('Inbox', isInbox: true);
      final blocked = _focus('Blocked');
      final work = _focus('Work');
      final state = _seed(
        defaultPriority: inbox,
        priorities: [inbox, blocked, work],
        lastOpenFocusId: work.id,
        priorityBlocksByPriority: {
          blocked.id: [
            PriorityBlockRow(
              id: Uuid.generate(),
              priorityId: blocked.id,
              createdBy: Uuid.generate(),
              orderValue: Order(0),
              effectiveAt: DateTime(2026, 5, 1, 9),
              duration: const Duration(hours: 1), // 9:00–10:00 covers 9:30
              archivedAt: null,
              createdAt: DateTime(2026, 5, 1, 9),
              updatedAt: DateTime(2026, 5, 1, 9),
            ),
          ],
        },
      );
      expect(state.priority.id, blocked.id);
    });

    group('session rung (needs a real Session)', () {
      late Store store;
      setUp(() {
        store = Store.forTesting(NativeDatabase.memory());
        Injector.appInstance
            .registerSingleton<Store>(() => store, override: true);
      });
      tearDown(() async {
        Injector.appInstance.removeByKey<Store>();
        await store.close();
      });

      test('a running session outranks the last open focus', () async {
        final inbox = _focus('Inbox', isInbox: true);
        final running = _focus('Running');
        final work = _focus('Work');
        final id = Uuid.generate();
        await store.into(store.sessions).insert(
              SessionsCompanion.insert(
                id: Value(id),
                start: DateTime(2026, 5, 1, 9),
                end: DateTime(2026, 5, 1, 9, 30),
                priorityId: Value(running.id),
              ),
            );
        final row = await (store.select(store.sessions)
              ..where((t) => t.id.equals(id.toBytes())))
            .getSingle();
        final session = Session.fromStore(row, priority: running);
        final state = _seed(
          defaultPriority: inbox,
          priorities: [inbox, running, work],
          lastOpenFocusId: work.id,
          session: session,
        );
        expect(state.priority.id, running.id);
      });
    });
  });

  group('pickRoleOpenFocus', () {
    test('returns the remembered focus when it is present', () {
      final a = _focus('A');
      final b = _focus('B');
      final c = _focus('C');
      expect(pickRoleOpenFocus([a, b, c], b.id).id, b.id);
    });

    test('returns the first focus when nothing is remembered', () {
      final a = _focus('A');
      final b = _focus('B');
      expect(pickRoleOpenFocus([a, b], null).id, a.id);
    });

    test('returns the first when the remembered focus is no longer in the role', () {
      final a = _focus('A');
      final b = _focus('B');
      expect(pickRoleOpenFocus([a, b], Uuid.generate()).id, a.id);
    });

    test('returns the only focus in a single-focus role', () {
      final a = _focus('A');
      expect(pickRoleOpenFocus([a], a.id).id, a.id);
    });
  });

  group('recordLastOpenFocusForRole / loadLastOpenFocusIdForRole', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ProfilePreferences.init();
    });

    test('record then load round-trips the focus id for its role', () async {
      final role = Uuid.generate();
      final work = _focus('Work', roleId: role);
      await recordLastOpenFocusForRole(work);
      expect(loadLastOpenFocusIdForRole(role), work.id);
    });

    test('a deliberately chosen role Inbox is remembered for its role', () async {
      final role = Uuid.generate();
      final inbox = _focus('Inbox', isInbox: true, roleId: role);
      await recordLastOpenFocusForRole(inbox);
      expect(loadLastOpenFocusIdForRole(role), inbox.id);
    });

    test('per-role slots are independent', () async {
      final roleA = Uuid.generate();
      final roleB = Uuid.generate();
      final a = _focus('A', roleId: roleA);
      final b = _focus('B', roleId: roleB);
      await recordLastOpenFocusForRole(a);
      await recordLastOpenFocusForRole(b);
      expect(loadLastOpenFocusIdForRole(roleA), a.id);
      expect(loadLastOpenFocusIdForRole(roleB), b.id);
    });

    test('records nothing for the Everything feed (null picked)', () async {
      final role = Uuid.generate();
      await recordLastOpenFocusForRole(null);
      expect(loadLastOpenFocusIdForRole(role), isNull);
    });

    test('records nothing for a role-less focus (no roleId)', () async {
      final roleless = _focus('Roleless'); // roleId == null
      await recordLastOpenFocusForRole(roleless); // must not throw
      // Nothing was keyed; an arbitrary role still reads null.
      expect(loadLastOpenFocusIdForRole(Uuid.generate()), isNull);
    });

    test('load returns null for a role with nothing recorded', () {
      expect(loadLastOpenFocusIdForRole(Uuid.generate()), isNull);
    });

    test('load returns null when the stored value is malformed', () async {
      final role = Uuid.generate();
      await ProfilePreferences.instance
          .setString('last_open_focus_role_$role', 'not-a-uuid');
      expect(loadLastOpenFocusIdForRole(role), isNull);
    });
  });
}
