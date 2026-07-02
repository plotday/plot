import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/thread_swipe_commands.dart';

/// Build a minimal [Priority] usable in unit tests.
Priority _testPriority() {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path('test'),
    order: Order(0),
    unread: false,
    role: 'member',
    isInbox: false,
    isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
    sendWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  final priority = _testPriority();

  ThreadSwipeCommands resolve(Thread t, {bool isOutsidePriority = false}) =>
      resolveThreadSwipeCommands(
        t,
        isOutsidePriority: isOutsidePriority,
        bump: true,
        finishOnBeforeRun: null,
      );

  // The model is **right = act on it (Done / engage), left = Move / menu**.
  // The left slots (Move short, menu long) are identical in every state.
  void expectLeftIsMoveThenMenu(Thread thread) {
    expect(resolve(thread).leftShort, isA<MoveThreadToPriority>());
    expect(resolve(thread).leftLong, isA<ShowThreadCommands>());
  }

  group('new update (not a to-do, unread)', () {
    final thread = Thread(priority: priority, unread: true);

    test('right short finishes (marks read, bumps to Done)', () {
      expect(resolve(thread).rightShort, isA<FinishThread>());
    });
    test('right long offers To do (not yet a to-do)', () {
      expect(resolve(thread).rightLong, isA<ToggleThreadActive>());
    });
    test('left short offers Move', () {
      expect(resolve(thread).leftShort, isA<MoveThreadToPriority>());
    });
    test('left long opens the menu', () {
      expect(resolve(thread).leftLong, isA<ShowThreadCommands>());
    });
  });

  group('doing (a to-do)', () {
    final thread = Thread(priority: priority, active: true);

    test('right short finishes', () {
      expect(resolve(thread).rightShort, isA<FinishThread>());
    });
    test('right long defers with Do later (already a to-do)', () {
      expect(resolve(thread).rightLong, isA<PickScheduleThread>());
    });
    test('left is Move then menu', () => expectLeftIsMoveThenMenu(thread));
  });

  group('a to-do that is also unread', () {
    final thread = Thread(priority: priority, active: true, unread: true);

    test('right short finishes (not the engage branch)', () {
      expect(resolve(thread).rightShort, isA<FinishThread>());
    });
    test('right long still defers with Do later', () {
      expect(resolve(thread).rightLong, isA<PickScheduleThread>());
    });
  });

  group('the Done list (read, not a to-do)', () {
    final thread = Thread(priority: priority, readAt: DateTime(2026, 1, 1));

    test('right short re-activates with To do', () {
      expect(resolve(thread).rightShort, isA<ToggleThreadActive>());
    });
    test('right long defers with Do later', () {
      expect(resolve(thread).rightLong, isA<PickScheduleThread>());
    });
    test('left is Move then menu', () => expectLeftIsMoveThenMenu(thread));
  });

  group('outside its priority', () {
    final thread = Thread(priority: priority, active: true, unread: true);

    test('all swipe slots are disabled', () {
      final cmds = resolve(thread, isOutsidePriority: true);
      expect(cmds.leftShort, isNull);
      expect(cmds.leftLong, isNull);
      expect(cmds.rightShort, isNull);
      expect(cmds.rightLong, isNull);
    });
  });

  test('right short and right long never resolve to the same command', () {
    final threads = [
      Thread(priority: priority, unread: true),
      Thread(priority: priority, readAt: DateTime(2026, 1, 1)),
      Thread(priority: priority, active: true),
      Thread(priority: priority, active: true, unread: true),
    ];
    for (final thread in threads) {
      final cmds = resolve(thread);
      if (cmds.rightShort != null && cmds.rightLong != null) {
        expect(
          cmds.rightShort.runtimeType,
          isNot(cmds.rightLong.runtimeType),
          reason: 'the same command would show at both short and long zones',
        );
      }
    }
  });
}
