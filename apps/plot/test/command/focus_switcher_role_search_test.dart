import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/analytics/conventions.dart';
import 'package:plot/command/command.dart';
import 'package:plot/store/store.dart';

/// The "Switch focuses" modal filters its [ChangeCurrentPriority] rows through
/// [CommandGroup.filter], which matches the command's visible title / subtitle.
/// To let a focus be found by its role (e.g. typing "marlow" to surface every
/// "AFC Marlow ›" focus) a focus command exposes its role name as hidden
/// [Command.searchTerms], matched but never displayed — gated on the user
/// having more than one role, mirroring [FocusLabel]'s role-prefix display.
void main() {
  Role role(String name) => Role.fromRow(
        RoleRow(
          id: Uuid.generate(),
          createdBy: Uuid.generate(),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
          name: name,
        ),
      );

  Priority focus(String title, {RoleId? roleId, bool isInbox = false}) {
    final row = PriorityRow(
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
      sendWindowSet: false,
    );
    return Priority.fromStore(row, draft: true);
  }

  tearDown(Role.clearCache);

  group('CommandGroup.filter matches hidden searchTerms', () {
    test('a command is found by its searchTerms, ranked below label matches',
        () {
      final byRole = _StubCommand(title: 'Finances', searchTerms: 'AFC Marlow');
      final byTitle = _StubCommand(title: 'Marlow Fund');

      // "marlow" matches the first by its hidden role term and the second by
      // its title.
      final result = CommandGroup.filter([byRole, byTitle], 'marlow');
      expect(result, containsAll(<Command>[byRole, byTitle]));

      // The visible-title match ranks above the searchTerms-only match.
      expect(result.first, same(byTitle));
      expect(result.last, same(byRole));
    });

    test('a query matching neither label nor searchTerms is excluded', () {
      final cmd = _StubCommand(title: 'Finances', searchTerms: 'AFC Marlow');
      expect(CommandGroup.filter([cmd], 'personal'), isEmpty);
    });
  });

  group('ChangeCurrentPriority exposes the role name as searchTerms', () {
    test('includes the owning role name with more than one role', () {
      final marlow = role('AFC Marlow');
      final personal = role('Personal');
      Role.setCacheForTesting([marlow, personal]);

      final command = ChangeCurrentPriority(focus('Finances', roleId: marlow.id));
      expect(command.searchTerms, 'AFC Marlow');
    });

    test('omits the role name when the user has a single role', () {
      final personal = role('Personal');
      Role.setCacheForTesting([personal]);

      final command =
          ChangeCurrentPriority(focus('Finances', roleId: personal.id));
      expect(command.searchTerms, isNull);
    });

    test('the synthetic Everything row carries no role searchTerms', () {
      final marlow = role('AFC Marlow');
      final personal = role('Personal');
      Role.setCacheForTesting([marlow, personal]);

      expect(ChangeCurrentPriority.everything().searchTerms, isNull);
    });
  });
}

/// Minimal concrete [Command] for exercising [CommandGroup.filter].
class _StubCommand extends Command {
  _StubCommand({required super.title, super.searchTerms})
      : super(
          eventObject: EventObject.priority,
          eventAction: EventAction.viewed,
        );

  @override
  Future<CommandReturn> run(BuildContext context) async => const CommandDone();
}
