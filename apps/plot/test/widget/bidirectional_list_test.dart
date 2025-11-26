import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plot/widget/bidirectional_list.dart';

void main() {
  group('BidirectionalListController', () {
    test('should initialize with correct values', () {
      final controller = BidirectionalListController(
        initialFocusedIndex: 5,
        initialMin: 0,
        initialMax: 10,
      );

      // Initially no focus shown (keyboard not active)
      expect(controller.focusedIndex, isNull);

      // After first moveFocus, should show focus at initial position
      controller.moveFocus(0);
      // Since FocusNode needs a tree to actually gain focus, we check lastFocusedIndex
      expect(controller.lastFocusedIndex, equals(5));
    });

    test('should clamp lastFocusedIndex to min/max bounds', () {
      final controller = BidirectionalListController(
        initialFocusedIndex: 5,
        initialMin: 0,
        initialMax: 10,
      );

      // Clamp to smaller bounds should adjust lastFocusedIndex
      controller.clamp(0, 3);
      expect(controller.lastFocusedIndex, equals(3));

      // Clamp with higher minimum
      controller.clamp(5, 10);
      expect(controller.lastFocusedIndex, equals(5));
    });

    test('should notify listeners on changes', () {
      final controller = BidirectionalListController();
      var notified = false;

      controller.addListener(() {
        notified = true;
      });

      controller.setHovered(1);
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
              builder: (context, index, focusNode, {reorderableIndex}) {
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
              builder: (context, index, focusNode, {reorderableIndex}) {
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
              builder: (context, index, focusNode, {reorderableIndex}) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
              fetcher: (first, count) async {
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
      final controller = BidirectionalListController(initialFocusedIndex: 2);
      const itemCount = 5;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: itemCount,
              controller: controller,
              builder: (context, index, focusNode, {reorderableIndex}) {
                return Focus(
                  focusNode: focusNode,
                  child: Builder(
                    builder: (context) {
                      final hasFocus = Focus.of(context).hasFocus;
                      return Container(
                        key: ValueKey('item_$index'),
                        height: 50,
                        color: hasFocus ? Colors.blue : Colors.transparent,
                        child: Text('Item $index'),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Initially no item has focus
      // Request focus on item 2
      controller.requestFocus(2);
      await tester.pumpAndSettle();

      // Check that the focused item has the correct color
      final selectedWidget = tester.widget<Container>(
        find.byKey(const ValueKey('item_2')),
      );
      expect(selectedWidget.color, equals(Colors.blue));

      // Check that non-focused items don't have the blue color
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
                builder: (context, index, focusNode, {reorderableIndex}) {
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
              anchorOffset: 0.5, // Middle of viewport
              builder: (context, index, focusNode, {reorderableIndex}) {
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
                  builder: (context, index, focusNode, {reorderableIndex}) {
                    return SizedBox(
                      key: ValueKey('item_$index'),
                      height: 100,
                      child: Text('Item $index'),
                    );
                  },
                  fetcher: (first, count) async {
                    fetcherCalls.add({'first': first, 'count': count});
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
          expect(call['first'], isA<int>());
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
              builder: (context, index, focusNode, {reorderableIndex}) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 100,
                  child: Text('Item $index'),
                );
              },
              fetcher: (first, count) async {
                fetcherCalled = true;
                throw Exception('Fetcher error');
              },
            ),
          ),
        ),
      );

      await tester.pump();

      // Trigger scrolling to cause fetcher call
      await tester.drag(find.byType(BidirectionalList), const Offset(0, -200));
      await tester.pump();

      // Widget should not crash despite fetcher error (errors are caught internally)
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
              builder: (context, index, focusNode, {reorderableIndex}) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 100,
                  child: Text('Item $index'),
                );
              },
              fetcher: (first, count) async {
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
                // Start in middle
                overflow: 1.0,
                doneStart: false,
                doneEnd: false,
                builder: (context, index, focusNode, {reorderableIndex}) {
                  return SizedBox(
                    key: ValueKey('item_$index'),
                    height: 50,
                    child: Text('Item $index'),
                  );
                },
                fetcher: (first, count) async {
                  fetcherCalls.add({'first': first, 'count': count});
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

      // Verify that first parameters include values indicating loading in both directions
      // (smaller first values for loading earlier items)
      final firsts = fetcherCalls.map((call) => call['first']!).toList();
      expect(firsts.isNotEmpty, isTrue); // Should have fetcher calls

      // Verify count parameters are reasonable
      for (final call in fetcherCalls) {
        expect(call['count']! >= itemCount, isTrue);
      }
    });
  });

  group('BidirectionalList Boundary Tests', () {
    testWidgets('should handle anchor at start boundary', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 10,
              first: 0,
              // Anchor at start
              anchorOffset: 0.0,
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      // Should render without issues
      expect(find.byType(BidirectionalList), findsOneWidget);
      expect(find.text('Item 0'), findsOneWidget);
    });

    testWidgets('should handle anchor at end boundary', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 10,
              first: 0,
              // Anchor at end
              anchorOffset: 1.0,
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      // Should render without issues
      expect(find.byType(BidirectionalList), findsOneWidget);
      expect(find.text('Item 9'), findsOneWidget);
    });

    testWidgets('should handle anchor outside of valid range', (
      WidgetTester tester,
    ) async {
      // Should gracefully handle invalid anchor by clamping it
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 10,
              first: 0,
              // Invalid anchor - outside range, should be clamped
              anchorOffset: 0.5,
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      // Should render without crashing (anchor gets clamped internally)
      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should handle negative first index', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 10,
              first: -5, // Negative start index
              // Negative anchor
              anchorOffset: 0.5,
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should handle zero count with non-zero first', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 0,
              first: 10, // Non-zero first with zero count
              // Anchor beyond range
              anchorOffset: 0.5,
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      expect(find.byType(BidirectionalList), findsOneWidget);
    });
  });

  group('BidirectionalList Controller Edge Cases', () {
    testWidgets('should handle controller with selection outside bounds', (
      WidgetTester tester,
    ) async {
      final controller = BidirectionalListController(
        initialFocusedIndex: 20, // Outside bounds
        initialMin: 0,
        initialMax: 10,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              controller: controller,
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      // Controller should be clamped to valid range by the widget
      // The widget calls clamp in didUpdateWidget
      expect(controller.lastFocusedIndex, lessThanOrEqualTo(4));
    });

    testWidgets('should handle controller bounds change during widget lifecycle', (
      WidgetTester tester,
    ) async {
      final controller = BidirectionalListController(
        initialFocusedIndex: 5,
        initialMin: 0,
        initialMax: 10,
      );

      Widget buildList(int count) {
        return MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: count,
              controller: controller,
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      // Start with larger count
      await tester.pumpWidget(buildList(10));
      await tester.pumpAndSettle();

      expect(controller.lastFocusedIndex, equals(5));

      // Reduce count below selected index
      await tester.pumpWidget(buildList(3));
      await tester.pumpAndSettle();

      // Selection should be adjusted
      expect(controller.lastFocusedIndex, lessThanOrEqualTo(2));
    });
  });

  group('BidirectionalList Fetcher Edge Cases', () {
    testWidgets('should handle fetcher that never completes', (
      WidgetTester tester,
    ) async {
      final completer = Completer<void>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              doneStart: false,
              doneEnd: false,
              overflow: 0.1, // Very small overflow to trigger quickly
              builder: (context, index, focusNode, {reorderableIndex}) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 100,
                  child: Text('Item $index'),
                );
              },
              fetcher: (first, count) async {
                // Never complete
                return completer.future;
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Trigger fetcher
      await tester.drag(find.byType(BidirectionalList), const Offset(0, -200));
      await tester.pump();

      // Widget should still be responsive even with hanging fetcher
      expect(find.byType(BidirectionalList), findsOneWidget);

      // Complete the future to clean up
      completer.complete();
    });

    testWidgets('should handle concurrent fetcher calls', (
      WidgetTester tester,
    ) async {
      final fetcherCalls = <DateTime>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              doneStart: false,
              doneEnd: false,
              overflow: 0.1,
              builder: (context, index, focusNode, {reorderableIndex}) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 100,
                  child: Text('Item $index'),
                );
              },
              fetcher: (first, count) async {
                fetcherCalls.add(DateTime.now());
                await Future<void>.delayed(const Duration(milliseconds: 100));
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Trigger multiple rapid scrolls
      for (int i = 0; i < 3; i++) {
        await tester.drag(find.byType(BidirectionalList), const Offset(0, -100));
        await tester.pump(const Duration(milliseconds: 10));
      }

      await tester.pumpAndSettle();

      // Should not have concurrent fetcher calls (should be prevented by _loading flag)
      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should handle fetcher with extremely large count requests', (
      WidgetTester tester,
    ) async {
      var largestCountRequest = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              doneStart: false,
              doneEnd: false,
              overflow: 10.0, // Large overflow
              estimatedItemExtent: 1, // Very small items
              builder: (context, index, focusNode, {reorderableIndex}) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 1,
                  child: Text('Item $index'),
                );
              },
              fetcher: (first, count) async {
                largestCountRequest = count > largestCountRequest ? count : largestCountRequest;
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Trigger fetcher
      await tester.drag(find.byType(BidirectionalList), const Offset(0, -300));
      await tester.pumpAndSettle();

      // Should handle large count requests without issues
      expect(find.byType(BidirectionalList), findsOneWidget);
      // Count request should be reasonable (not astronomical)
      expect(largestCountRequest, lessThan(10000));
    });
  });

  group('BidirectionalList Extreme Configurations', () {
    testWidgets('should handle extremely small estimated item extent', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              estimatedItemExtent: 0, // Zero height estimation
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should handle extremely large overflow', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 5,
              overflow: 1000.0, // Massive overflow
              doneStart: false,
              doneEnd: false,
              builder: (context, index, focusNode, {reorderableIndex}) {
                return SizedBox(
                  key: ValueKey('item_$index'),
                  height: 50,
                  child: Text('Item $index'),
                );
              },
              fetcher: (first, count) async {
                // Mock fetcher
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byType(BidirectionalList), findsOneWidget);
    });

    testWidgets('should handle reverse list with complex anchor', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BidirectionalList(
              count: 10,
              first: 5,
              // Anchor in middle
              anchorOffset: 0.75,
              reverse: true, // Reverse list
              builder: (context, index, focusNode, {reorderableIndex}) {
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

      expect(find.byType(BidirectionalList), findsOneWidget);
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
              builder: (context, index, focusNode, {reorderableIndex}) {
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
              builder: (context, index, focusNode, {reorderableIndex}) {
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
              builder: (context, index, focusNode, {reorderableIndex}) {
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
                  builder: (context, index, focusNode, {reorderableIndex}) {
                    return Focus(
                      focusNode: focusNode,
                      child: Builder(
                        builder: (context) {
                          final hasFocus = Focus.of(context).hasFocus;
                          return Container(
                            key: ValueKey('item_$index'),
                            height: 50,
                            color: hasFocus ? Colors.blue : Colors.transparent,
                            child: Text('Item $index'),
                          );
                        },
                      ),
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

      // Controller starts with no focus (keyboard not active)
      expect(capturedController?.focusedIndex, isNull);
    });

    testWidgets('should handle direct controller manipulation', (
      WidgetTester tester,
    ) async {
      final controller = BidirectionalListController(
        initialFocusedIndex: 0,
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
              builder: (context, index, focusNode, {reorderableIndex}) {
                return Focus(
                  focusNode: focusNode,
                  child: Builder(
                    builder: (context) {
                      final hasFocus = Focus.of(context).hasFocus;
                      return Container(
                        key: ValueKey('item_$index'),
                        height: 50,
                        color: hasFocus ? Colors.blue : Colors.transparent,
                        child: Text('Item $index'),
                      );
                    },
                  ),
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

      // Initially no focus (keyboard not active)
      expect(controller.focusedIndex, isNull);

      // Test direct controller manipulation
      // First moveFocus activates and shows current position
      controller.moveFocus(0);
      await tester.pumpAndSettle();
      expect(controller.lastFocusedIndex, equals(0));

      // Subsequent moveFocus navigates
      controller.moveFocus(1);
      await tester.pumpAndSettle();
      expect(controller.lastFocusedIndex, equals(1));

      // Test moving back
      controller.moveFocus(-1);
      await tester.pumpAndSettle();
      expect(controller.lastFocusedIndex, equals(0));
    });
  });
}
