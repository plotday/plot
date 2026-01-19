import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

import 'package:plot/widget/bidirectional_list.dart';

@widgetbook.UseCase(name: 'Add to start', type: BidirectionalList)
Widget buildAddToStart(BuildContext context) {
  return const AddToStartDemo();
}

class AddToStartDemo extends StatefulWidget {
  const AddToStartDemo({super.key});

  @override
  State<AddToStartDemo> createState() => _AddToStartDemoState();
}

class _AddToStartDemoState extends State<AddToStartDemo> {
  late final BidirectionalListController _controller;
  Timer? _timer;

  // Items stored as strings, index 0 is the oldest item
  List<String> _items = ['Item 0', 'Item 1', 'Item 2'];

  // first tracks the index of the first item in the BidirectionalList
  // We start at 0 and decrement as we add items to the start
  int _first = 0;

  @override
  void initState() {
    super.initState();
    _controller = BidirectionalListController();

    // Add a new item to the start every second
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _first -= 1;
        _items.insert(0, 'Item $_first');
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 400,
      child: BidirectionalList(
        controller: _controller,
        first: _first,
        count: _items.length,
        doneStart: true,
        doneEnd: true,
        builder: (context, index, focusNode, {reorderableIndex}) {
          // Map global index to local array position
          final localIndex = index - _first;
          if (localIndex < 0 || localIndex >= _items.length) {
            return null;
          }

          return Container(
            key: ValueKey('item_$index'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFFE0E0E0)),
              ),
            ),
            child: Text(_items[localIndex]),
          );
        },
      ),
    );
  }
}

@widgetbook.UseCase(name: 'Insert before anchor', type: BidirectionalList)
Widget buildInsertBeforeAnchor(BuildContext context) {
  return const InsertBeforeAnchorDemo();
}

class InsertBeforeAnchorDemo extends StatefulWidget {
  const InsertBeforeAnchorDemo({super.key});

  @override
  State<InsertBeforeAnchorDemo> createState() => _InsertBeforeAnchorDemoState();
}

class _InsertBeforeAnchorDemoState extends State<InsertBeforeAnchorDemo> {
  late final BidirectionalListController _controller;
  Timer? _timer;

  // Items are stored by their index. Anchor is at index 0.
  // When we add items "before" the anchor, they get negative indices.
  // Map key is the item index, value is the display string.
  final Map<int, String> _items = {
    0: 'Anchor Item (stays in place)',
    1: 'Item 1 (below anchor)',
    2: 'Item 2 (below anchor)',
  };

  // first is the lowest index, count is total number of items
  int _first = 0;
  int _newItemCounter = 0;

  @override
  void initState() {
    super.initState();
    _controller = BidirectionalListController();

    // Insert a new item before the anchor (negative index) every second
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _newItemCounter += 1;
        _first -= 1;
        _items[_first] = 'New Item $_newItemCounter (above anchor)';
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 400,
      child: BidirectionalList(
        controller: _controller,
        first: _first,
        count: _items.length,
        doneStart: true,
        doneEnd: true,
        builder: (context, index, focusNode, {reorderableIndex}) {
          final item = _items[index];
          if (item == null) {
            return null;
          }

          final isAnchor = index == 0;

          return Container(
            key: ValueKey('item_$index'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isAnchor ? const Color(0xFFFFF3E0) : null,
              border: const Border(
                bottom: BorderSide(color: Color(0xFFE0E0E0)),
              ),
            ),
            child: Text(
              item,
              style: TextStyle(
                fontWeight: isAnchor ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        },
      ),
    );
  }
}
