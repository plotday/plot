import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;

import 'package:plot/widget/infinite_list.dart';

@widgetbook.UseCase(name: 'Basic list', type: InfiniteList)
Widget buildBasicList(BuildContext context) {
  return const BasicListDemo();
}

class BasicListDemo extends StatefulWidget {
  const BasicListDemo({super.key});

  @override
  State<BasicListDemo> createState() => _BasicListDemoState();
}

class _BasicListDemoState extends State<BasicListDemo> {
  late final InfiniteListController _controller;
  Timer? _timer;

  List<String> _items = ['Item 0', 'Item 1', 'Item 2'];

  @override
  void initState() {
    super.initState();
    _controller = InfiniteListController();

    // Add a new item every second
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _items.add('Item ${_items.length}');
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
      child: InfiniteList(
        controller: _controller,
        count: _items.length,
        doneEnd: true,
        builder: (context, index, focusNode, {reorderableIndex}) {
          if (index < 0 || index >= _items.length) {
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
            child: Text(_items[index]),
          );
        },
      ),
    );
  }
}
