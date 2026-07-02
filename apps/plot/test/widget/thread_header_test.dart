import 'package:flutter_test/flutter_test.dart';
import 'package:rrule/rrule.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/thread.dart';

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

/// Regression test for empty participant-header bands on thread rows.
///
/// A thread whose only contact is an id that never resolves to an actor (e.g.
/// the Plot Updates topic threads, whose `contacts` reference a global "Plot"
/// twist instance that isn't synced to a given client) used to reserve the
/// header name slot forever — the slot is gated on the *stable* id set so it
/// doesn't shift while names warm in, but the name never arrived, leaving a
/// permanent empty band above the title. The slot must collapse once actor
/// loading has finished with nothing to show.
void main() {
  group('reserveContactsLabel', () {
    test('reserves while actors are still loading (avoids layout shift)', () {
      expect(
        reserveContactsLabel(
          isChannelThread: false,
          hasContactIds: true,
          actorsLoaded: false,
          hasResolvedLabel: false,
        ),
        isTrue,
      );
    });

    test('keeps the slot once a name has resolved', () {
      expect(
        reserveContactsLabel(
          isChannelThread: false,
          hasContactIds: true,
          actorsLoaded: true,
          hasResolvedLabel: true,
        ),
        isTrue,
      );
    });

    test(
      'collapses when loading finished with no resolvable name '
      '(the empty-band bug)',
      () {
        expect(
          reserveContactsLabel(
            isChannelThread: false,
            hasContactIds: true,
            actorsLoaded: true,
            hasResolvedLabel: false,
          ),
          isFalse,
        );
      },
    );

    test('never reserves when there are no contact ids', () {
      expect(
        reserveContactsLabel(
          isChannelThread: false,
          hasContactIds: false,
          actorsLoaded: false,
          hasResolvedLabel: false,
        ),
        isFalse,
      );
    });

    test('never reserves for channel threads (they use the breadcrumb)', () {
      expect(
        reserveContactsLabel(
          isChannelThread: true,
          hasContactIds: true,
          actorsLoaded: true,
          hasResolvedLabel: true,
        ),
        isFalse,
      );
    });
  });

  // The trailing command cluster is overlaid via a [Positioned] whose negative
  // right offset is tuned for a ghost icon BUTTON: the button box extends past
  // the content edge by its internal icon padding, landing the glyph (inset by
  // that padding) right at the content edge — the same edge as the header
  // timestamp. Only a trailing-most item that is NOT a padded ghost button (a
  // bare RSVP chip, or a read-only assignee avatar rendered without its button
  // wrapper) needs a compensating inset. A writable assignee avatar IS a padded
  // ghost button (ThreadAssignee wraps it in FButton.icon), so insetting it
  // again double-pads it ~one icon-padding inboard of the timestamp.
  group('trailingClusterInset', () {
    const pad = 7.5;

    test('no inset for a writable assignee avatar (already a padded button)', () {
      expect(
        trailingClusterInset(
          hasRsvpChip: false,
          hasAssignee: true,
          assigneeIsReadOnly: false,
          ghostIconPadding: pad,
        ),
        0.0,
      );
    });

    test('insets a read-only assignee avatar (bare, no button padding)', () {
      expect(
        trailingClusterInset(
          hasRsvpChip: false,
          hasAssignee: true,
          assigneeIsReadOnly: true,
          ghostIconPadding: pad,
        ),
        pad,
      );
    });

    test('insets a trailing RSVP chip (bare pill)', () {
      expect(
        trailingClusterInset(
          hasRsvpChip: true,
          hasAssignee: false,
          assigneeIsReadOnly: false,
          ghostIconPadding: pad,
        ),
        pad,
      );
    });

    test('no inset when a writable assignee trails an RSVP chip', () {
      // Cluster order ends … · rsvp · assignee, so the writable (padded) avatar
      // is the trailing-most item and needs no compensation.
      expect(
        trailingClusterInset(
          hasRsvpChip: true,
          hasAssignee: true,
          assigneeIsReadOnly: false,
          ghostIconPadding: pad,
        ),
        0.0,
      );
    });

    test('insets when a read-only assignee trails an RSVP chip', () {
      expect(
        trailingClusterInset(
          hasRsvpChip: true,
          hasAssignee: true,
          assigneeIsReadOnly: true,
          ghostIconPadding: pad,
        ),
        pad,
      );
    });

    test('no inset when the cluster ends in a ghost icon button', () {
      expect(
        trailingClusterInset(
          hasRsvpChip: false,
          hasAssignee: false,
          assigneeIsReadOnly: false,
          ghostIconPadding: pad,
        ),
        0.0,
      );
    });
  });

  // The header band surfaces the occurrence date (and time, when the event is
  // timed) for calendar-event threads. Timed events used to be suppressed here
  // because the agenda's block header rendered the time — but in the flat feed
  // there is no block header, so the date vanished. These lock the re-added
  // display and the "nearest occurrence" (next, else most recent past) pick.
  group('threadScheduleLabelDate', () {
    final priority = _testPriority();
    final today = Date(2026, 6, 26);

    test('surfaces a timed event\'s own date and time '
        '(regression: was hidden)', () {
      final event = Thread(
        priority: priority,
        title: 'Standup',
        at: DateTimeRange(DateTime(2026, 6, 30, 14), DateTime(2026, 6, 30, 15)),
      );
      expect(
        threadScheduleLabelDate(event, isTodoBase: false, today: today),
        DateTime(2026, 6, 30, 14),
      );
    });

    test('surfaces an all-day event\'s date with no time', () {
      final event = Thread(
        priority: priority,
        title: 'Holiday',
        on: CustomDateRange(Date(2026, 6, 30), null),
      );
      final result =
          threadScheduleLabelDate(event, isTodoBase: false, today: today);
      expect(result?.toDate(), Date(2026, 6, 30));
      expect(result?.toTimeOfDay().isMidnight, isTrue);
    });

    test('hides the label for a plain todo with no schedule', () {
      final todo = Thread(priority: priority, title: 'Buy milk');
      expect(
        threadScheduleLabelDate(todo, isTodoBase: true, today: today),
        isNull,
      );
    });

    test('recurring: targets the next upcoming occurrence, not the anchor', () {
      // Weekly series anchored in the past; the nearest upcoming instance
      // (2026-06-29), not the 2026-06-22 anchor, is shown.
      final series = Thread(
        priority: priority,
        title: 'Weekly sync',
        at: DateTimeRange(DateTime(2026, 6, 22, 14), DateTime(2026, 6, 22, 15)),
        recurrenceRule: RecurrenceRule(frequency: Frequency.weekly),
      );
      final result =
          threadScheduleLabelDate(series, isTodoBase: false, today: today);
      expect(result?.toDate(), Date(2026, 6, 29));
    });

    test('recurring: falls back to the most recent past occurrence', () {
      // A finished weekly series (COUNT=2) whose occurrences are all in the
      // past still anchors to its latest occurrence (2026-06-08) rather than
      // vanishing.
      final series = Thread(
        priority: priority,
        title: 'Old standup',
        at: DateTimeRange(DateTime(2026, 6, 1, 9), DateTime(2026, 6, 1, 10)),
        recurrenceRule: RecurrenceRule(frequency: Frequency.weekly, count: 2),
      );
      final result =
          threadScheduleLabelDate(series, isTodoBase: false, today: today);
      expect(result?.toDate(), Date(2026, 6, 8));
    });
  });
}
