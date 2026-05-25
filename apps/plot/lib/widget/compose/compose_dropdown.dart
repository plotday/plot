import 'package:flutter/services.dart';

import 'package:plot/widget/widget.dart';

/// A focus-driven dropdown anchored to a field. The parent owns the
/// [FocusNode] and the [items] list; this widget owns:
///   - the overlay rendering,
///   - the highlighted-index cursor,
///   - arrow-key / Enter handling (Escape is handled by the inner [Dropdown]).
///
/// Open the dropdown by calling [DropdownController.show] from the parent
/// (typically when the field's input gains focus or its text changes).
class ComposeDropdown<T> extends StatefulWidget {
  const ComposeDropdown({
    super.key,
    required this.controller,
    required this.items,
    required this.itemBuilder,
    required this.onSelected,
    required this.child,
    this.maxHeight = 280,
    this.emptyBuilder,
  });

  final DropdownController controller;
  final List<T> items;

  /// Builds a single dropdown row. [highlighted] is true when the cursor sits
  /// on this item (via arrow-key navigation).
  final Widget Function(BuildContext context, T item, bool highlighted)
      itemBuilder;

  /// Called when the user taps or presses Enter on an item.
  final void Function(T item) onSelected;

  final Widget child;

  /// Maximum height of the scrollable list before it starts clipping.
  final double maxHeight;

  /// Widget shown when [items] is empty. Defaults to [SizedBox.shrink].
  final WidgetBuilder? emptyBuilder;

  @override
  State<ComposeDropdown<T>> createState() => ComposeDropdownState<T>();
}

class ComposeDropdownState<T> extends State<ComposeDropdown<T>> {
  int _highlightedIndex = 0;

  @override
  void didUpdateWidget(ComposeDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      // Reset the highlight when the candidate list changes (e.g. user
      // typed and the filtered list shrank).
      _highlightedIndex = widget.items.isEmpty
          ? 0
          : _highlightedIndex.clamp(0, widget.items.length - 1);
    }
  }

  /// Drives navigation from the parent's keyboard listener.
  ///
  /// Returns true if the key was consumed so the parent can stop propagation.
  bool handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!widget.controller.isShowing) return false;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (widget.items.isEmpty) return false;
      widget.onSelected(widget.items[_highlightedIndex]);
      return true;
    }
    return false;
  }

  void _move(int delta) {
    if (widget.items.isEmpty) return;
    setState(() {
      _highlightedIndex =
          (_highlightedIndex + delta) % widget.items.length;
      if (_highlightedIndex < 0) {
        _highlightedIndex += widget.items.length;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dropdown(
      controller: widget.controller,
      dropdown: _buildOverlay(context),
      child: widget.child,
    );
  }

  Widget _buildOverlay(BuildContext context) {
    if (widget.items.isEmpty) {
      return widget.emptyBuilder?.call(context) ?? const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.items.length,
        itemBuilder: (context, i) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelected(widget.items[i]),
            child: widget.itemBuilder(
              context,
              widget.items[i],
              i == _highlightedIndex,
            ),
          );
        },
      ),
    );
  }
}
