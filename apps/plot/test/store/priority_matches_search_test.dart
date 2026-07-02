import 'package:flutter_test/flutter_test.dart';

import 'package:plot/store/store.dart';

/// [Priority.matchesSearch] backs the focus filter in every "pick a focus"
/// modal (new-thread target, reschedule, focus block). When the user has more
/// than one role the search corpus includes the focus's owning role name, so a
/// focus is findable by its role as well as its own / ancestor names. With a
/// single role the role name is redundant noise and is excluded — mirroring
/// [FocusLabel]'s role-prefix display gate.
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

  Priority focus(String title, {RoleId? roleId}) {
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

  tearDown(Role.clearCache);

  test('matches on the owning role name with more than one role', () {
    final marlow = role('AFC Marlow');
    final personal = role('Personal');
    Role.setCacheForTesting([marlow, personal]);

    final finances = focus('Finances', roleId: marlow.id);

    // Findable by the role name, the focus name, or a mix of both.
    expect(finances.matchesSearch('marlow'), isTrue);
    expect(finances.matchesSearch('finances'), isTrue);
    expect(finances.matchesSearch('afc fin'), isTrue);

    // A different role's name must not match this focus.
    expect(finances.matchesSearch('personal'), isFalse);
  });

  test('ignores the role name when the user has a single role', () {
    final personal = role('Personal');
    Role.setCacheForTesting([personal]);

    final finances = focus('Finances', roleId: personal.id);

    // With one role the role name is not part of the search corpus.
    expect(finances.matchesSearch('personal'), isFalse);
    // The focus name still matches.
    expect(finances.matchesSearch('finances'), isTrue);
  });

  test('matches the title when no roles are cached', () {
    Role.setCacheForTesting([]);

    final finances = focus('Finances');

    expect(finances.matchesSearch('fin'), isTrue);
    expect(finances.matchesSearch('zzz'), isFalse);
  });
}
