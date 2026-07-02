import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/thread_carousel.dart';

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

void main() {
  final priority = _testPriority();
  Thread mk(String title) => Thread(priority: priority, title: title);

  // Build a carousel whose center/preview are cheap stubs, recording opens.
  Widget host({
    required List<Thread> threads,
    required int initialIndex,
    ThreadId? centerThreadId,
    required List<Thread> opened,
    bool reserveLeftEdgeBackZone = false,
  }) {
    final centerId = centerThreadId ??
        (initialIndex >= 0 && threads.isNotEmpty
            ? threads[initialIndex].id
            : threads.first.id);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 400,
        height: 800,
        child: ThreadCarousel(
          centerThreadId: centerId,
          threads: threads,
          initialIndex: initialIndex,
          centerBuilder: (id) => Center(child: Text('center:$id')),
          previewBuilder: (t) => Center(child: Text('preview:${t.id}')),
          onThreadChanged: opened.add,
          reserveLeftEdgeBackZone: reserveLeftEdgeBackZone,
        ),
      ),
    );
  }

  testWidgets('renders the live center thread', (tester) async {
    final threads = [mk('a'), mk('b'), mk('c')];
    await tester.pumpWidget(host(threads: threads, initialIndex: 1, opened: []));
    expect(find.text('center:${threads[1].id}'), findsOneWidget);
  });

  testWidgets('inert single thread (not in feed) does not swipe',
      (tester) async {
    final only = mk('only');
    final opened = <Thread>[];
    // initialIndex -1 → centerThreadId rendered as the lone page.
    await tester.pumpWidget(host(
      threads: const [],
      initialIndex: -1,
      centerThreadId: only.id,
      opened: opened,
    ));
    expect(find.text('center:${only.id}'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('swipe left opens the next thread', (tester) async {
    final threads = [mk('a'), mk('b'), mk('c')];
    final opened = <Thread>[];
    await tester.pumpWidget(
        host(threads: threads, initialIndex: 1, opened: opened));
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened.map((t) => t.id), [threads[2].id]);
    expect(find.text('center:${threads[2].id}'), findsOneWidget);
  });

  testWidgets('swipe right opens the previous thread', (tester) async {
    final threads = [mk('a'), mk('b'), mk('c')];
    final opened = <Thread>[];
    await tester.pumpWidget(
        host(threads: threads, initialIndex: 1, opened: opened));
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened.map((t) => t.id), [threads[0].id]);
    expect(find.text('center:${threads[0].id}'), findsOneWidget);
  });

  testWidgets('at the first thread, swipe right rubber-bands', (tester) async {
    final threads = [mk('a'), mk('b'), mk('c')];
    final opened = <Thread>[];
    await tester.pumpWidget(
        host(threads: threads, initialIndex: 0, opened: opened));
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('at the last thread, swipe left rubber-bands', (tester) async {
    final threads = [mk('a'), mk('b'), mk('c')];
    final opened = <Thread>[];
    await tester.pumpWidget(
        host(threads: threads, initialIndex: 2, opened: opened));
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('drag starting in the left-edge zone does not open a neighbor',
      (tester) async {
    final threads = [mk('a'), mk('b'), mk('c')];
    final opened = <Thread>[];
    await tester.pumpWidget(host(
      threads: threads,
      initialIndex: 1,
      opened: opened,
      reserveLeftEdgeBackZone: true,
    ));
    // Start the pointer at x=10 (inside the 20px edge zone) and drag right.
    final gesture = await tester.startGesture(const Offset(10, 400));
    await tester.pump(); // let onPointerDown freeze the PageView
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('drag starting outside the edge zone still opens a neighbor',
      (tester) async {
    final threads = [mk('a'), mk('b'), mk('c')];
    final opened = <Thread>[];
    await tester.pumpWidget(host(
      threads: threads,
      initialIndex: 1,
      opened: opened,
      reserveLeftEdgeBackZone: true,
    ));
    // Start at x=200 (outside the zone) and fling right → previous thread.
    await tester.flingFrom(
        const Offset(200, 400), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(opened.map((t) => t.id), [threads[0].id]);
  });

  group('CarouselScrollCache', () {
    testWidgets('save then offsetFor round-trips per thread', (tester) async {
      final id = mk('x').id;
      late CarouselScrollCache cache;
      await tester.pumpWidget(
        CarouselScrollCache(
          offsets: {},
          child: Builder(
            builder: (context) {
              cache = CarouselScrollCache.maybeOf(context)!;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(cache.offsetFor(id), isNull);
      cache.save(id, 123.5);
      expect(cache.offsetFor(id), 123.5);
    });

    testWidgets('maybeOf is null when no cache is present', (tester) async {
      CarouselScrollCache? found;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            found = CarouselScrollCache.maybeOf(context);
            return const SizedBox();
          },
        ),
      );
      expect(found, isNull);
    });
  });
}
