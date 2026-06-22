import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/thread_carousel_nav.dart';

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
  );
  return Priority.fromStore(row, draft: true);
}

void main() {
  group('shouldUseThreadCarousel', () {
    test('enabled on native iOS and Android', () {
      expect(
        shouldUseThreadCarousel(isWeb: false, platform: TargetPlatform.iOS),
        isTrue,
      );
      expect(
        shouldUseThreadCarousel(isWeb: false, platform: TargetPlatform.android),
        isTrue,
      );
    });

    test('disabled on web even for a mobile platform', () {
      expect(
        shouldUseThreadCarousel(isWeb: true, platform: TargetPlatform.iOS),
        isFalse,
      );
    });

    test('disabled on desktop platforms', () {
      for (final p in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(shouldUseThreadCarousel(isWeb: false, platform: p), isFalse);
      }
    });
  });

  group('threadFromAgendaItem', () {
    final priority = _testPriority();

    test('returns the thread for a thread item', () {
      final thread = Thread(priority: priority, title: 'hi');
      expect(threadFromAgendaItem(AgendaThreadItem(thread))?.id, thread.id);
    });

    test('returns null for a header item and for null', () {
      expect(threadFromAgendaItem(null), isNull);
      expect(
        threadFromAgendaItem(const AgendaHeaderItem(date: null)),
        isNull,
      );
    });
  });

  group('feedThreads', () {
    final priority = _testPriority();

    test('keeps thread items in order and drops headers', () {
      final a = Thread(priority: priority, title: 'a');
      final b = Thread(priority: priority, title: 'b');
      final items = <AgendaItem>[
        const AgendaHeaderItem(date: null),
        AgendaThreadItem(a),
        AgendaThreadItem(b),
      ];
      expect(feedThreads(items).map((t) => t.id), [a.id, b.id]);
    });

    test('is empty for an empty or header-only feed', () {
      expect(feedThreads(const []), isEmpty);
      expect(feedThreads(const [AgendaHeaderItem(date: null)]), isEmpty);
    });
  });
}
