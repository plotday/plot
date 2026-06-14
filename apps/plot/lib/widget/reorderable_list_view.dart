import 'package:flutter/foundation.dart' show listEquals, setEquals;
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
    this.handleOnly = false,
    super.key,
  });

  final List<T> list;
  final ListItemWidgetBuilder<T> itemBuilder;
  final ReorderCallback onReorder;
  final bool shrinkWrap;

  /// When false (default), the whole item is the drag target: the list wraps
  /// each row in a [ReorderableDragStartListener] (desktop, pointer-down) or a
  /// [ReorderableDelayedDragStartListener] (mobile, long-press), and the
  /// builder receives `null` for `reorderableIndex`. This is right for a list
  /// of single-row items (focus rows, threads, notes).
  ///
  /// When true, the list does NOT auto-wrap the item; instead it passes the
  /// real index to [itemBuilder] (a non-null `reorderableIndex`) and the item
  /// is responsible for wrapping only its own drag handle with a
  /// [ReorderableDragStartListener] / [ReorderableDelayedDragStartListener]
  /// (see `DragHandle` / `ListTile.reorderableIndex`). Use this when an item is
  /// itself a composite that contains other interactive (or nested-draggable)
  /// regions — e.g. a role section whose header is the handle but whose body is
  /// an inner reorderable focus list. Without this, the outer drag target would
  /// blanket the inner list and steal its drag gestures.
  final bool handleOnly;

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
  /// The optimistic copy that [build] actually renders. On a drop we reorder
  /// this immediately, then call [ReorderableListView.onReorder] to persist —
  /// the parent's rebuilt list catches up only after that async round trip.
  late List<T> list;

  /// The key order we optimistically applied on the most recent in-app drop
  /// and are still waiting for the parent to echo back (once its async
  /// persistence — typically a Drift `.save()` → bloc re-emit — lands). Null
  /// when no local reorder is outstanding.
  ///
  /// REGRESSION GUARD — do not remove. Callers rebuild [ReorderableListView.list]
  /// as a *fresh* instance on every build (e.g. PrioritiesList re-derives
  /// `focuses` each time), so `widget.list != oldWidget.list` is *always* true
  /// and [didUpdateWidget] fires on every ancestor rebuild. Between a drop and
  /// the save propagating, any such rebuild (a sibling bloc emitting, a
  /// `ScrollEdgeFade` toggling its `ShaderMask`, a selection change, …)
  /// re-passes the still-stale pre-drop order. Blindly adopting it flashed the
  /// dropped row back to its original slot for a frame before the save settled
  /// it again. While [_pendingKeys] is set we ignore those stale echoes and
  /// keep the optimistic order, yielding only when the parent's order matches
  /// our optimism or the membership genuinely changes. See
  /// test/widget/reorderable_list_view_test.dart.
  List<Key>? _pendingKeys;

  Key _keyOf(T item) => widget.keyExtractor?.call(item) ?? ValueKey(item);

  List<Key> _keysOf(Iterable<T> items) => [for (final i in items) _keyOf(i)];

  @override
  void initState() {
    list = [...widget.list];
    super.initState();
  }

  @override
  void didUpdateWidget(covariant ReorderableListView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pendingKeys;
    if (pending != null) {
      final incoming = _keysOf(widget.list);
      if (listEquals(incoming, pending)) {
        // The save propagated: the parent now agrees with our optimism. Adopt
        // the fresh instances (they carry any updated data) and stop guarding.
        setState(() {
          list = [...widget.list];
          _pendingKeys = null;
        });
      } else if (!setEquals(incoming.toSet(), _keysOf(list).toSet())) {
        // Membership changed out from under the pending reorder (item added or
        // removed) — a real structural update that must win over the optimism.
        setState(() {
          list = [...widget.list];
          _pendingKeys = null;
        });
      }
      // Otherwise this is a stale echo of the pre-drop order; keep the
      // optimistic list so the dropped row stays put.
      return;
    }
    // No reorder in flight: always track the parent. Adopt fresh instances even
    // when the order is unchanged so item data (unread/active churn, …) stays
    // current.
    setState(() {
      list = [...widget.list];
    });
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
        final key = _keyOf(item);
        if (widget.handleOnly) {
          // Handle-only: the list does NOT wrap the item. The item gets the
          // real index and self-wraps just its drag handle (header), so the
          // rest of the item — including any nested reorderable — keeps its own
          // gestures. `material.ReorderableListView.builder` still requires a
          // keyed child at the top level, so attach the key here.
          return KeyedSubtree(
            key: key,
            child: widget.itemBuilder(context, item, index),
          );
        }
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
      onReorderItem: (int oldIndex, int newIndex) {
        setState(() {
          final item = list.removeAt(oldIndex);
          list.insert(newIndex, item);
          // Record the order we just applied so didUpdateWidget can recognise
          // (and ignore) the stale pre-drop echoes that arrive before
          // widget.onReorder's async persistence propagates back down.
          _pendingKeys = _keysOf(list);
        });
        widget.onReorder(oldIndex, newIndex);
      },
    );
  }
}
