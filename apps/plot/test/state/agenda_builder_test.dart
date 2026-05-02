import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_builder.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Build a minimal [Priority] usable in unit tests.
/// Uses [Priority.fromStore] with [draft] = true so the constructor
/// does not try to register the priority with a parent or the Store.
Priority _testPriority() {
  final row = PriorityRow(
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
    attentionWindowSet: false,
    seeWithinRequestsSet: false,
    seeWithinUpdatesSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  test('empty threads list produces empty model', () {
    final context = _testPriority();
    final model = AgendaBuilder.build(
      threads: const [],
      context: context,
      horizonDays: 30,
    );
    expect(model.sections, isEmpty);
    expect(model, AgendaModel.empty);
  });
}
