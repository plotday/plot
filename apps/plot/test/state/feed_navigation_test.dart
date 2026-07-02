import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/feed_navigation.dart';
import 'package:plot/store/store.dart';

Priority _priority() {
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

AgendaHeaderItem _header(ActivitySection s, {Date? date}) => AgendaHeaderItem(
  date: date,
  text: ActivitySectionMarker.encode(s),
);

void main() {
  final priority = _priority();
  Thread thread(String title) => Thread(priority: priority, title: title);
  AgendaThreadItem row(Thread t) => AgendaThreadItem(t);

  final a = thread('a');
  final b = thread('b');
  final c = thread('c');
  final done1 = thread('done1');

  group('nextThreadAfterStateChange', () {
    test('opens the thread below within the same section', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        row(b),
        row(c),
      ];
      final nav = nextThreadAfterStateChange(items, a.id, multiPanel: true);
      expect(nav.open?.id, b.id);
      expect(nav.stay, isFalse);
    });

    test('crosses from Active into Scheduled', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        _header(ActivitySection.scheduled, date: Date(2026, 6, 20)),
        row(b),
      ];
      final nav = nextThreadAfterStateChange(items, a.id, multiPanel: true);
      expect(nav.open?.id, b.id);
    });

    test('last thread before Done opens the previous thread above', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        row(b),
        _header(ActivitySection.activity),
        row(done1),
      ];
      final nav = nextThreadAfterStateChange(items, b.id, multiPanel: true);
      expect(nav.open?.id, a.id, reason: 'works bottom-up: prefer above');
      expect(nav.stay, isFalse);
    });

    test('last thread before Done with nothing above falls through to Done',
        () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        _header(ActivitySection.activity),
        row(done1),
      ];
      final nav = nextThreadAfterStateChange(items, a.id, multiPanel: true);
      expect(nav.open?.id, done1.id);
    });

    test('changed thread in Done stays open (rule 3)', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        _header(ActivitySection.activity),
        row(done1),
        row(b),
      ];
      final nav = nextThreadAfterStateChange(items, done1.id, multiPanel: true);
      expect(nav.open, isNull);
      expect(nav.stay, isTrue);
    });

    test('bottom thread with no Done section opens the thread above', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
        row(b),
      ];
      final nav = nextThreadAfterStateChange(items, b.id, multiPanel: true);
      expect(nav.open?.id, a.id);
    });

    test('only thread in the feed: no navigation, not a stay', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
      ];
      final nav = nextThreadAfterStateChange(items, a.id, multiPanel: true);
      expect(nav.open, isNull);
      expect(nav.stay, isFalse);
    });

    test('changed thread not in the list stays open', () {
      final items = [
        _header(ActivitySection.doing),
        row(a),
      ];
      final nav = nextThreadAfterStateChange(items, b.id, multiPanel: true);
      expect(nav.open, isNull);
      expect(nav.stay, isTrue);
    });

    group('filtered feed advances within the filter', () {
      // The bloc passes the filtered/visible feed (unread-only, mute-only or
      // focus-scope) so Done advances to the next visible thread and never to
      // one the filter omitted from [items]. stayWhenNothingToOpen keeps the
      // just-finished thread open when the filtered subset has nothing left,
      // rather than falling back to the compose page.
      test('opens the next unread thread below', () {
        final items = [
          _header(ActivitySection.doing),
          row(a),
          row(b),
          row(c),
        ];
        final nav = nextThreadAfterStateChange(
          items,
          a.id,
          multiPanel: true,
          stayWhenNothingToOpen: true,
        );
        expect(nav.open?.id, b.id);
        expect(nav.stay, isFalse);
      });

      test('stays open when it was the last unread (only row)', () {
        final items = [
          _header(ActivitySection.doing),
          row(a),
        ];
        final nav = nextThreadAfterStateChange(
          items,
          a.id,
          multiPanel: true,
          stayWhenNothingToOpen: true,
        );
        expect(nav.open, isNull);
        // stay (not the compose-page sentinel): the filter auto-clears and the
        // full feed reappears, so the just-finished thread stays open.
        expect(nav.stay, isTrue);
      });

      test('still opens the thread above when one exists', () {
        final items = [
          _header(ActivitySection.doing),
          row(a),
          row(b),
        ];
        final nav = nextThreadAfterStateChange(
          items,
          b.id,
          multiPanel: true,
          stayWhenNothingToOpen: true,
        );
        expect(nav.open?.id, a.id);
        expect(nav.stay, isFalse);
      });
    });

    group('single panel never repositions', () {
      // In single panel the user explicitly drilled into the thread, so a
      // state change keeps it open; they pop back to the list when ready.
      test('a thread that would open the next below instead stays open', () {
        final items = [
          _header(ActivitySection.doing),
          row(a),
          row(b),
          row(c),
        ];
        final nav = nextThreadAfterStateChange(items, a.id, multiPanel: false);
        expect(nav.open, isNull);
        expect(nav.stay, isTrue);
      });

      test('the last actionable thread does not fall back to compose', () {
        final items = [
          _header(ActivitySection.doing),
          row(a),
        ];
        final nav = nextThreadAfterStateChange(items, a.id, multiPanel: false);
        expect(nav.open, isNull);
        // stay (not the "nothing left to open" sentinel), so FinishThread
        // keeps the thread open instead of opening the compose page.
        expect(nav.stay, isTrue);
      });
    });
  });
}
