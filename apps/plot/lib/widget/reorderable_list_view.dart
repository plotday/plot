import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:platform_builder/platform_builder.dart';

typedef ListItemWidgetBuilder<T> = Widget Function(
    BuildContext context, T item);

class ReorderableListView<T> extends StatefulWidget {
  const ReorderableListView({
    required this.list,
    required this.itemBuilder,
    required this.onReorder,
    this.shrinkWrap = false,
    super.key,
  });

  final List<T> list;
  final ListItemWidgetBuilder<T> itemBuilder;
  final ReorderCallback onReorder;
  final bool shrinkWrap;

  @override
  ReorderableListViewState<T> createState() => ReorderableListViewState<T>();
}

class ReorderableListViewState<T> extends State<ReorderableListView<T>> {
  late List<T> list;

  @override
  void initState() {
    list = [...widget.list];
    super.initState();
  }

  @override
  void didUpdateWidget(covariant ReorderableListView<T> oldWidget) {
    if (widget.list != oldWidget.list) {
      setState(() {
        list = [...widget.list];
      });
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return material.ReorderableListView.builder(
      itemCount: list.length,
      primary: false,
      shrinkWrap: widget.shrinkWrap,
      buildDefaultDragHandles: false,
      proxyDecorator: Platform.instance.isNative
          ? (Widget child, int index, Animation<double> animation) => child
          : null,
      itemBuilder: (context, index) => ReorderableDragStartListener(
        index: index,
        key: ValueKey(list[index]),
        child: widget.itemBuilder(context, list[index]),
      ),
      onReorder: (int oldIndex, int newIndex) {
        setState(() {
          if (oldIndex < newIndex) {
            newIndex -= 1;
          }
          final item = list.removeAt(oldIndex);
          list.insert(newIndex, item);
        });
        widget.onReorder(oldIndex, newIndex);
      },
    );
  }
}
