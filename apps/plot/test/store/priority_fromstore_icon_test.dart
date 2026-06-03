import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

/// Regression test for the focus-icon edit bug: editing a focus, changing the
/// icon, and saving did nothing — reopening the editor showed the default
/// icon again.
///
/// Root cause: `Priority.fromStore` forwarded every `PriorityRow` column to its
/// `super(...)` constructor EXCEPT `icon`, so any `Priority` rebuilt via
/// `fromStore` (including the result of `copyWith`) silently dropped its icon to
/// null. `save()` then persisted `icon: Value(null)`, so the picked icon never
/// reached the database.
PriorityRow _row({String? icon}) => PriorityRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      title: 'Test',
      path: Path('test'),
      order: const Order(0),
      root: false,
      unread: false,
      role: 'member',
      icon: icon,
      attentionWindowSet: false,
      seeWithinSet: false,
      earlyNotificationsEnabledSet: false,
      notifyWindowSet: false,
    );

void main() {
  test('fromStore preserves the icon column', () {
    final priority = Priority.fromStore(_row(icon: 'house'), draft: true);
    expect(priority.icon, 'house');
  });

  test('copyWith sets a new icon and survives the fromStore round-trip', () {
    final priority = Priority.fromStore(_row(icon: 'house'), draft: true);
    final updated = priority.copyWith(icon: const Value('bug'));
    expect(updated.icon, 'bug');
  });

  test('copyWith preserves an existing icon when icon is not passed', () {
    final priority = Priority.fromStore(_row(icon: 'house'), draft: true);
    final updated = priority.copyWith(title: 'Renamed');
    expect(updated.icon, 'house');
  });

  test('toCompanion carries the icon for persistence', () {
    final priority = Priority.fromStore(_row(icon: 'house'), draft: true);
    final companion = priority.toCompanion(false);
    expect(companion.icon, const Value('house'));
  });
}
