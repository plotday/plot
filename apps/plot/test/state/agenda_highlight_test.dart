import 'package:flutter_test/flutter_test.dart';
import 'package:plot/page/agenda.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';

/// Build a minimal [Priority] usable in unit tests.
Priority _priority({String path = 'test'}) {
  final row = PriorityRow(
    id: Uuid.generate(),
    createdBy: Uuid.generate(),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    title: 'Test',
    path: Path(path),
    order: Order(0),
    root: false,
    unread: false,
    role: 'member',
    attentionWindowSet: false,
    seeWithinSet: false,
    earlyNotificationsEnabledSet: false,
    notifyWindowSet: false,
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  final now = DateTime(2026, 5, 29, 12, 0);

  // A focus block whose window covers [now]. `agendaHighlightIndex` only
  // reads blockPriority / parentBlockId / dateTimeRange / now / thread, so
  // the AgendaBlock itself is intentionally omitted.
  AgendaHeaderItem currentFocusBlock(Priority p, {String id = 'fb_cur'}) =>
      AgendaHeaderItem(
        blockPriority: p,
        parentBlockId: id,
        dateTimeRange: DateTimeRange(
          now.subtract(const Duration(hours: 1)),
          now.add(const Duration(hours: 1)),
        ),
      );

  // A focus block scheduled later today — does not cover [now].
  AgendaHeaderItem futureFocusBlock(Priority p, {String id = 'fb_future'}) =>
      AgendaHeaderItem(
        blockPriority: p,
        parentBlockId: id,
        dateTimeRange: DateTimeRange(
          now.add(const Duration(hours: 2)),
          now.add(const Duration(hours: 3)),
        ),
      );

  // An event in progress (carries `now: true`, like EventBlock.isCurrent).
  AgendaHeaderItem currentEvent(Priority p, Thread event) => AgendaHeaderItem(
    blockPriority: p,
    thread: event,
    now: true,
    parentBlockId: 'e_${event.id}',
    dateTimeRange: event.at,
  );

  test('auto-highlights the current-time block of the viewed priority', () {
    final p = _priority();
    final items = <AgendaItem>[
      const AgendaHeaderItem(date: Date(2026, 5, 29), now: true),
      currentFocusBlock(p),
    ];

    final index = agendaHighlightIndex(
      items: items,
      currentPriorityId: p.id,
      currentEventId: null,
      selectedBlockId: null,
      now: now,
    );

    expect(index, 1);
  });

  test('skips the date-section header even though it is marked now', () {
    final p = _priority();
    final items = <AgendaItem>[
      // blockPriority == null, so never highlightable despite now: true.
      const AgendaHeaderItem(date: Date(2026, 5, 29), now: true),
      futureFocusBlock(p),
    ];

    final index = agendaHighlightIndex(
      items: items,
      currentPriorityId: p.id,
      currentEventId: null,
      selectedBlockId: null,
      now: now,
    );

    // Only a future block for the viewed priority → nothing highlighted.
    expect(index, isNull);
  });

  test('does not auto-highlight a future block just because the priority '
      'is viewed', () {
    final p = _priority();
    final items = <AgendaItem>[futureFocusBlock(p)];

    final index = agendaHighlightIndex(
      items: items,
      currentPriorityId: p.id,
      currentEventId: null,
      selectedBlockId: null,
      now: now,
    );

    expect(index, isNull);
  });

  test('does not auto-highlight when the current block belongs to another '
      'priority', () {
    final viewed = _priority(path: 'viewed');
    final other = _priority(path: 'other');
    final items = <AgendaItem>[currentFocusBlock(other)];

    final index = agendaHighlightIndex(
      items: items,
      currentPriorityId: viewed.id,
      currentEventId: null,
      selectedBlockId: null,
      now: now,
    );

    expect(index, isNull);
  });

  test('directly-selected block is highlighted even when it is not current',
      () {
    final p = _priority();
    final items = <AgendaItem>[
      currentFocusBlock(p, id: 'fb_cur'),
      futureFocusBlock(p, id: 'fb_future'),
    ];

    final index = agendaHighlightIndex(
      items: items,
      currentPriorityId: p.id,
      currentEventId: null,
      selectedBlockId: 'fb_future',
      now: now,
    );

    // The tapped future block wins over the current-time block.
    expect(index, 1);
  });

  test('directly-selected event is highlighted by thread id', () {
    final p = _priority();
    final eventA = Thread(priority: p, title: 'A');
    final eventB = Thread(priority: p, title: 'B');
    final items = <AgendaItem>[
      currentEvent(p, eventA),
      currentEvent(p, eventB),
    ];

    final index = agendaHighlightIndex(
      items: items,
      currentPriorityId: p.id,
      currentEventId: eventB.id,
      selectedBlockId: null,
      now: now,
    );

    expect(index, 1);
  });

  test('an in-progress event of the viewed priority auto-highlights', () {
    final p = _priority();
    final event = Thread(priority: p, title: 'Standup');
    final items = <AgendaItem>[currentEvent(p, event)];

    final index = agendaHighlightIndex(
      items: items,
      currentPriorityId: p.id,
      currentEventId: null,
      selectedBlockId: null,
      now: now,
    );

    expect(index, 0);
  });
}
