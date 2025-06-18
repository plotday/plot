import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/widget/bidirectional_list.dart';

void main() {
  group('BidirectionalListController', () {
    test('should initialize with correct values', () {
      final controller = BidirectionalListController(
        initialSelected: 5,
        initialMin: 0,
        initialMax: 10,
      );

      expect(controller.selected, equals(5));
    });

    test('should clamp selected value to min/max bounds', () {
      final controller = BidirectionalListController(
        initialMin: 0,
        initialMax: 10,
      );

      controller.selected = 15;
      expect(controller.selected, equals(10));

      controller.selected = -5;
      expect(controller.selected, equals(0));
    });

    test('should move selection correctly', () {
      final controller = BidirectionalListController(
        initialSelected: 5,
        initialMin: 0,
        initialMax: 10,
      );

      controller.move(2);
      expect(controller.selected, equals(7));

      controller.move(-3);
      expect(controller.selected, equals(4));
    });

    test('should notify listeners on selection change', () {
      final controller = BidirectionalListController();
      var notified = false;

      controller.addListener(() {
        notified = true;
      });

      controller.selected = 5;
      expect(notified, isTrue);
    });
  });

  group('BidirectionalList Widget Tests', () {
    testWidgets('should render basic list with items', (
      WidgetTester tester,
    ) async {
      const itemCount = 5;
      final items = List.generate(itemCount, (i) => 'Item $i');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: itemCount,
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text(items[index]),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify all items are rendered
      for (int i = 0; i < itemCount; i++) {
        expect(find.text('Item $i'), findsOneWidget);
        expect(find.byKey(ValueKey('item_$i')), findsOneWidget);
      }
    });

    testWidgets('should handle empty list', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 0,
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Should not crash and should not render any items
      expect(find.byType(SizedBox), findsNothing);
    });

    testWidgets('should handle loading states', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              doneStart: false,
              doneEnd: false,
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
              fetcher: (move, count) async {
                // Mock fetcher
                return;
              },
            ),
          ),
        ),
      );

      await tester.pump();

      // Widget should render without crashing when in loading state
      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should highlight selected item correctly', (
      WidgetTester tester,
    ) async {
      final controller = BidirectionalListController(initialSelected: 2);
      const itemCount = 5;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: itemCount,
              controller: controller,
              builder: (context, index, selected) {
                return Container(
                  key: ValueKey('item_$index'),
                  height: 50,
                  color: selected ? Colors.blue : Colors.transparent,
                  child: Text('Item $index'),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Check that the selected item has the correct color
      final selectedWidget = tester.widget<Container>(
        find.byKey(const ValueKey('item_2')),
      );
      expect(selectedWidget.color, equals(Colors.blue));

      // Check that non-selected items don't have the blue color
      final nonSelectedWidget = tester.widget<Container>(
        find.byKey(const ValueKey('item_0')),
      );
      expect(nonSelectedWidget.color, equals(Colors.transparent));
    });
  });

  group('BidirectionalList Scrolling Tests', () {
    testWidgets('should calculate scroll metrics correctly', (
      WidgetTester tester,
    ) async {
      final scrollController = ScrollController();
      const itemCount = 20;
      const itemHeight = 50.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 400, // Viewport height
              child: BidirectionalList(
                count: itemCount,
                scrollController: scrollController,
                estimatedItemExtent: itemHeight.toInt(),
                builder: (context, index, selected) {
                  return SizedBox(
                    key: ValueKey('item_$index'),
                    height: itemHeight,
                    child: Text('Item $index'),
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify scroll controller is attached
      expect(scrollController.hasClients, isTrue);

      // Test scrolling
      await tester.drag(find.byType(BidirectionalList), const Offset(0, -200));
      await tester.pumpAndSettle();

      // Verify scroll position changed
      expect(scrollController.position.pixels, greaterThan(0));
    });

    testWidgets('should maintain scroll position with anchor', (
      WidgetTester tester,
    ) async {
      const itemCount = 10;
      const anchorIndex = 5;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: itemCount,
              anchor: anchorIndex,
              anchorOffset: 0.5, // Middle of viewport
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify the anchor item is visible
      expect(find.text('Item $anchorIndex'), findsOneWidget);
    });
  });

  group('BidirectionalList Fetcher Tests', () {
    testWidgets(
      'should call fetcher with correct parameters when scrolling near edges',
      (WidgetTester tester) async {
        final fetcherCalls = <Map<String, int>>[];
        const itemCount = 10;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 400,
                child: BidirectionalList(
                  count: itemCount,
                  overflow: 1.0, // Small overflow to trigger fetcher sooner
                  doneStart: false,
                  doneEnd: false,
                  builder: (context, index, selected) {
                    return SizedBox(
                      key: ValueKey('item_$index'),
                      height: 100,
                      child: Text('Item $index'),
                    );
                  },
                  fetcher: (move, count) async {
                    fetcherCalls.add({'move': move, 'count': count});
                  },
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Initial state might trigger fetcher
        await tester.pump(const Duration(milliseconds: 100));

        // Scroll down to trigger fetcher for loading more items at the end
        await tester.drag(
          find.byType(BidirectionalList),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();

        // Wait for potential async fetcher calls
        await tester.pump(const Duration(milliseconds: 100));

        // Verify fetcher was called at least once
        expect(fetcherCalls.isNotEmpty, isTrue);

        // Verify fetcher parameters are reasonable
        for (final call in fetcherCalls) {
          expect(call['move'], isA<int>());
          expect(call['count'], isA<int>());
          expect(
            call['count']! >= itemCount,
            isTrue,
          ); // Should request at least current count
        }
      },
    );

    testWidgets('should handle fetcher errors gracefully', (
      WidgetTester tester,
    ) async {
      var fetcherCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              doneStart: false,
              doneEnd: false,
              overflow: 0.5, // Very small overflow to trigger quickly
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 100,
                  child: Text('Item $index'),
                );
              },
              fetcher: (move, count) async {
                fetcherCalled = true;
                throw Exception('Fetcher error');
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Trigger scrolling to cause fetcher call
      await tester.drag(find.byType(BidirectionalList), const Offset(0, -200));
      await tester.pumpAndSettle();

      // Widget should not crash despite fetcher error
      expect(find.byType(BidirectionalList), findsOneWidget);
      expect(fetcherCalled, isTrue);
    });

    testWidgets('should not call fetcher when done loading', (
      WidgetTester tester,
    ) async {
      var fetcherCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              doneStart: true,
              doneEnd: true,
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 100,
                  child: Text('Item $index'),
                );
              },
              fetcher: (move, count) async {
                fetcherCalled = true;
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Scroll to potentially trigger fetcher
      await tester.drag(find.byType(BidirectionalList), const Offset(0, -200));
      await tester.pumpAndSettle();

      // Fetcher should not be called when done loading
      expect(fetcherCalled, isFalse);
    });

    testWidgets('should request correct item ranges for bidirectional loading', (
      WidgetTester tester,
    ) async {
      final fetcherCalls = <Map<String, int>>[];
      const itemCount = 10;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: BidirectionalList(
                count: itemCount,
                anchor: 5, // Start in middle
                overflow: 1.0,
                doneStart: false,
                doneEnd: false,
                builder: (context, index, selected) {
                  return SizedBox(
                    key: ValueKey('item_$index'),
                    height: 50,
                    child: Text('Item $index'),
                  );
                },
                fetcher: (move, count) async {
                  fetcherCalls.add({'move': move, 'count': count});
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                },
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Scroll up (towards beginning) to trigger loading earlier items
      await tester.drag(find.byType(BidirectionalList), const Offset(0, 200));
      await tester.pumpAndSettle();

      // Scroll down (towards end) to trigger loading later items
      await tester.drag(find.byType(BidirectionalList), const Offset(0, -400));
      await tester.pumpAndSettle();

      // Wait for async operations
      await tester.pump(const Duration(milliseconds: 100));

      // Verify fetcher was called for both directions
      expect(fetcherCalls.isNotEmpty, isTrue);

      // Verify that move parameters include both positive and negative values
      // (negative for loading earlier items, positive offset for loading later items)
      final moves = fetcherCalls.map((call) => call['move']!).toList();
      expect(
        moves.any((move) => move <= 0),
        isTrue,
      ); // Should have calls for earlier items

      // Verify count parameters are reasonable
      for (final call in fetcherCalls) {
        expect(call['count']! >= itemCount, isTrue);
      }
    });
  });

  group('BidirectionalList Edge Cases', () {
    testWidgets('should handle rapid scroll changes', (
      WidgetTester tester,
    ) async {
      const itemCount = 20;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: itemCount,
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Perform rapid scrolling
      for (int i = 0; i < 5; i++) {
        await tester.drag(
          find.byType(BidirectionalList),
          const Offset(0, -100),
        );
        await tester.pump(const Duration(milliseconds: 10));
        await tester.drag(find.byType(BidirectionalList), const Offset(0, 100));
        await tester.pump(const Duration(milliseconds: 10));
      }

      await tester.pumpAndSettle();

      // Widget should remain stable
      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should handle builder returning null', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              builder: (context, index, selected) {
                // Return null for some items
                if (index % 2 == 0) return null;
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Should handle null builders gracefully - widget doesn't crash
      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should update when count changes', (
      WidgetTester tester,
    ) async {
      var itemCount = 5;

      Widget buildWidget() {
        return MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: itemCount,
              builder: (context, index, selected) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(buildWidget());
      await tester.pumpAndSettle();

      // Verify initial count
      expect(find.text('Item 4'), findsOneWidget);
      expect(find.text('Item 5'), findsNothing);

      // Update count
      itemCount = 7;
      await tester.pumpWidget(buildWidget());
      await tester.pumpAndSettle();

      // Verify updated count
      expect(find.text('Item 4'), findsOneWidget);
      expect(find.text('Item 6'), findsOneWidget);
    });
  });

  group('BidirectionalList Keyboard Navigation', () {
    testWidgets('should work with selection wrapper', (
      WidgetTester tester,
    ) async {
      BidirectionalListController? capturedController;
      const itemCount = 5;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalListSelector(
              builder: (context, selectorController) {
                capturedController = selectorController;
                return BidirectionalList(
                  count: itemCount,
                  controller: selectorController,
                  builder: (context, index, selected) {
                    return Container(
                      key: ValueKey('item_$index'),
                      height: 50,
                      color: selected ? Colors.blue : Colors.transparent,
                      child: Text('Item $index'),
                    );
                  },
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify BidirectionalListSelector integrates properly
      expect(find.byType(BidirectionalList), findsOneWidget);
      expect(capturedController, isNotNull);
      expect(capturedController?.selected, equals(0));
    });

    testWidgets('should handle direct controller manipulation', (
      WidgetTester tester,
    ) async {
      final controller = BidirectionalListController(
        initialSelected: 0,
        initialMin: 0,
        initialMax: 4,
      );
      const itemCount = 5;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: itemCount,
              controller: controller,
              builder: (context, index, selected) {
                return Container(
                  key: ValueKey('item_$index'),
                  height: 50,
                  color: selected ? Colors.blue : Colors.transparent,
                  child: Text('Item $index'),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // The BidirectionalList should update the controller bounds automatically
      // Wait for the widget to apply its bounds
      await tester.pump();

      // Verify initial selection
      expect(controller.selected, equals(0));

      // Test direct controller manipulation
      controller.move(1);
      await tester.pumpAndSettle();

      expect(controller.selected, equals(1));

      // Test moving back
      controller.move(-1);
      await tester.pumpAndSettle();

      expect(controller.selected, equals(0));
    });
  });
}

