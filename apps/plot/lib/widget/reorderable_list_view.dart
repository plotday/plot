import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:platform_builder/platform_builder.dart';

import 'package:plot/util/platform.dart';

typedef ListItemWidgetBuilder<T> = Widget Function(
    BuildContext context, T item, int? reorderableIndex);

class ReorderableListView<T> extends StatefulWidget {
  const ReorderableListView({
    required this.list,
    required this.itemBuilder,
    required this.onReorder,
    this.keyExtractor,
    this.shrinkWrap = false,
    super.key,
  });

  final List<T> list;
  final ListItemWidgetBuilder<T> itemBuilder;
  final ReorderCallback onReorder;
  final bool shrinkWrap;

  /// Override how a stable Key is derived from a list element. Defaults
  /// to `ValueKey(item)`. Override this for element types whose `==`
  /// folds in mutable state (e.g. `Priority`'s unread/active flags) —
  /// otherwise the key changes whenever that state mutates, which
  /// remounts the row and drops the State of every descendant
  /// (StreamBuilders, animation state, …). The drift child's
  /// `ReorderableDragStartListener` uses this key, so a stable
  /// `ValueKey(item.id)` here keeps the row's element identity stable
  /// across rebuilds.
  final Key Function(T item)? keyExtractor;

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
      itemBuilder: (context, index) {
        final item = list[index];
        final key = widget.keyExtractor?.call(item) ?? ValueKey(item);
        if (hasPhysicalKeyboard()) {
          // Desktop: full item is drag target, starts immediately on
          // pointer-down.
          return ReorderableDragStartListener(
            index: index,
            key: key,
            child: widget.itemBuilder(context, item, null),
          );
        }
        // Mobile: full item is drag target, but a long-press is required
        // to start the drag so the list can still be scrolled by a
        // normal touch-drag. No drag handle is rendered; items receive
        // `null` for [reorderableIndex] and skip any handle rendering.
        return material.ReorderableDelayedDragStartListener(
          index: index,
          key: key,
          child: widget.itemBuilder(context, item, null),
        );
      },
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
