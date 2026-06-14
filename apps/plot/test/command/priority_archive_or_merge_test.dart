import 'package:flutter_test/flutter_test.dart';
import 'package:plot/command/priority.dart';
import 'package:plot/store/store.dart';

PriorityRow _row({DateTime? archivedAt}) => PriorityRow(
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
      isInbox: false,
      isFyi: false,
      archivedAt: archivedAt,
      attentionWindowSet: false,
      seeWithinSet: false,
      earlyNotificationsEnabledSet: false,
      notifyWindowSet: false,
    );

void main() {
  test('active focus with threads → Merge into…', () {
    final p = Priority.fromStore(_row(), draft: true, hasThreads: true);
    final cmd = archiveOrMergeCommands(p).first;
    expect(cmd, isA<MergeFocusInto>());
    expect(cmd.title, 'Merge into…');
  });

  test('active focus without threads → Archive', () {
    final p = Priority.fromStore(_row(), draft: true, hasThreads: false);
    final cmd = archiveOrMergeCommands(p).first;
    expect(cmd, isA<TogglePriorityArchived>());
    expect(cmd.title, 'Archive');
  });

  test('archived focus → Un-archive (never Merge)', () {
    final p = Priority.fromStore(
      _row(archivedAt: DateTime(2026, 1, 2)),
      draft: true,
      hasThreads: true,
    );
    final cmd = archiveOrMergeCommands(p).first;
    expect(cmd, isA<TogglePriorityArchived>());
    expect(cmd.title, 'Un-archive');
  });
}
