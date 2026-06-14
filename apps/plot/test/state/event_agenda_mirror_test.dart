import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';

Priority _priority(String path) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: path,
    path: Path(path),
    order: const Order(0),
    root: false,
    unread: false,
    role: 'member',
    isInbox: false,
      isFyi: false,
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  // Regression coverage for the cross-focus Event Agenda jank: switching
  // between a focus and an agenda event in another focus rendered an
  // intermediate frame mixing the new event prefix with the previous
  // focus's rows (and, in reverse, dropped the prefix a frame before the
  // rows swapped). The mirror must be deferred while NowBloc's context
  // has moved ahead of the feed's, and the prefix must only render for
  // an event the feed's context owns.
  group('shouldDeferEventMirror', () {
    final focusA = _priority('a');
    final focusB = _priority('b');

    test('applies immediately when NowBloc and the feed agree', () {
      expect(
        shouldDeferEventMirror(
          nowContextId: focusA.id,
          feedContextId: focusA.id,
        ),
        isFalse,
      );
    });

    test('defers while a cross-focus transition is in flight', () {
      expect(
        shouldDeferEventMirror(
          nowContextId: focusB.id,
          feedContextId: focusA.id,
        ),
        isTrue,
      );
    });

    test('applies when NowBloc has no context yet', () {
      expect(
        shouldDeferEventMirror(nowContextId: null, feedContextId: focusA.id),
        isFalse,
      );
    });
  });

  group('eventAgendaEventFor', () {
    final focusA = _priority('a');
    final focusB = _priority('b');

    test('returns the event when the feed context owns it', () {
      final event = Thread(priority: focusA, draft: true);
      expect(eventAgendaEventFor(event, focusA.id), same(event));
    });

    test('suppresses an event filed in another focus', () {
      final event = Thread(priority: focusB, draft: true);
      expect(eventAgendaEventFor(event, focusA.id), isNull);
    });

    test('passes through null', () {
      expect(eventAgendaEventFor(null, focusA.id), isNull);
    });
  });
}
