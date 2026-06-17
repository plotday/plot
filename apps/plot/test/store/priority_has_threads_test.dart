import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';

PriorityRow _row({DateTime? archivedAt}) => PriorityRow(
      id: Uuid.generate(),
      createdBy: Uuid.generate(),
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      title: 'Test',
      path: Path('test'),
      order: const Order(0),
      unread: false,
      role: 'member',
      isInbox: false,
      isFyi: false,
      archivedAt: archivedAt,
      attentionWindowSet: false,
      seeWithinSet: false,
      earlyNotificationsEnabledSet: false,
      notifyWindowSet: false,
    );

void main() {
  test('defaults to false when not computed', () {
    final priority = Priority.fromStore(_row(), draft: true);
    expect(priority.hasThreads, isFalse);
  });

  test('fromStore carries the computed hasThreads flag', () {
    final priority = Priority.fromStore(_row(), draft: true, hasThreads: true);
    expect(priority.hasThreads, isTrue);
  });

  test('withHasThreads returns a copy with the flag set', () {
    final priority = Priority.fromStore(_row(), draft: true);
    expect(priority.withHasThreads(true).hasThreads, isTrue);
    expect(priority.withHasThreads(false).hasThreads, isFalse);
  });

  test('hasThreads survives the copyWith / fromStore round-trip', () {
    final priority =
        Priority.fromStore(_row(), draft: true, hasThreads: true);
    final updated = priority.copyWith(title: 'Renamed');
    expect(updated.hasThreads, isTrue,
        reason: 'copyWith must forward _hasThreadsComputed through fromStore');
  });
}
