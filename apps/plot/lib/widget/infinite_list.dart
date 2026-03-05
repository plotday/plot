import 'dart:math';

import 'package:flutter/rendering.dart';

import 'package:plot/widget/widget.dart';
import 'logging.dart';

class InfiniteListController extends ChangeNotifier {
  InfiniteListController({
    int? initialFocusedIndex,
    int initialMin = 0,
    int initialMax = 0,
  }) : _min = initialMin,
       _max = initialMax,
       _lastFocusedIndex = initialFocusedIndex;

  // Map of FocusNodes by item index
  final Map<int, FocusNode> _focusNodes = {};

  int? _hoveredIndex;
  int? _lastFocusedIndex;
  int? _draggingIndex;
  int _min;
  int _max;

  int? get hoveredIndex => _hoveredIndex;
  int? get lastFocusedIndex => _lastFocusedIndex;
  int? get draggingIndex => _draggingIndex;

  void setDragging(int? index) {
    if (_draggingIndex != index) {
      _draggingIndex = index;
      if (index != null) {
        _hoveredIndex = null;
      }
      notifyListeners();
    }
  }

  /// Get the currently focused index, or null if no item has focus.
  int? get focusedIndex {
    for (final entry in _focusNodes.entries) {
      if (entry.value.hasFocus) {
        return entry.key;
      }
    }
    return null;
  }

  /// Get or create a FocusNode for the given index.
  FocusNode getFocusNode(int index) {
    if (!_focusNodes.containsKey(index)) {
      final node = FocusNode();
      node.addListener(() {
        if (node.hasFocus) {
          _lastFocusedIndex = index;
          // Clear hover when an item gains focus via keyboard
          if (_hoveredIndex != null) {
            _hoveredIndex = null;
            notifyListeners();
          }
        }
      });
      _focusNodes[index] = node;
    }
    return _focusNodes[index]!;
  }

  void clamp(int min, int max) {
    _min = min;
    _max = max;
    // Clamp last focused index
    if (_lastFocusedIndex != null && _lastFocusedIndex! < _min) {
      _lastFocusedIndex = _min;
    }
    if (_lastFocusedIndex != null && _lastFocusedIndex! > _max) {
      _lastFocusedIndex = _max;
    }
  }

  void setHovered(int? index) {
    if (_hoveredIndex != index) {
      _hoveredIndex = index;
      // Clear focus when hovering (as per requirements)
      if (index != null) {
        // Unfocus any currently focused node
        for (final node in _focusNodes.values) {
          if (node.hasFocus) {
            node.unfocus();
          }
        }
      }
      notifyListeners();
    }
  }

  void clearFocus() {
    // Unfocus all nodes
    for (final node in _focusNodes.values) {
      if (node.hasFocus) {
        node.unfocus();
      }
    }
    notifyListeners();
  }

  /// Request focus on a specific index.
  void requestFocus(int index) {
    if (index >= _min && index <= _max) {
      getFocusNode(index).requestFocus();
    }
  }

  /// Move focus by an offset (e.g., +1 for down, -1 for up).
  void moveFocus(int offset) {
    // Clear hover when using keyboard navigation
    _hoveredIndex = null;

    // Find currently focused index
    int? currentIndex;
    for (final entry in _focusNodes.entries) {
      if (entry.value.hasFocus) {
        currentIndex = entry.key;
        break;
      }
    }

    // If nothing is currently focused, show highlight at last position (or min) without moving
    if (currentIndex == null) {
      final startIndex = _lastFocusedIndex ?? _min;
      requestFocus(startIndex);
      return;
    }

    // Calculate new index
    int newIndex = currentIndex + offset;

    // Clamp to valid range
    if (newIndex < _min) newIndex = _min;
    if (newIndex > _max) newIndex = _max;

    // Request focus on new index
    requestFocus(newIndex);
  }

  @override
  void dispose() {
    // Dispose all focus nodes
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _focusNodes.clear();
    super.dispose();
  }
}

class ActivateListSelectionIntent extends Intent {
  const ActivateListSelectionIntent();
}

class MoveListSelectionIntent extends Intent {
  const MoveListSelectionIntent(this.offset);
  final int offset;
}

class InfiniteListSelector extends StatefulWidget {
  final Widget Function(BuildContext context, InfiniteListController controller)
  builder;

  final ValueChanged<int?>? onSelectionChanged;
  final void Function(int)? onActivate;
  final bool reverse;
  final bool autoActivateKeyboard;
  final int? initialFocusedIndex;

  const InfiniteListSelector({
    super.key,
    required this.builder,
    this.onSelectionChanged,
    this.onActivate,
    this.reverse = false,
    this.autoActivateKeyboard = false,
    this.initialFocusedIndex,
  });

  @override
  InfiniteListSelectorState createState() => InfiniteListSelectorState();
}

class InfiniteListSelectorState extends State<InfiniteListSelector> {
  late final InfiniteListController controller = InfiniteListController(
    initialFocusedIndex: widget.initialFocusedIndex,
  );

  @override
  void initState() {
    super.initState();
    controller.addListener(_handleFocusChange);

    // Auto-focus first item if requested
    if (widget.autoActivateKeyboard && widget.initialFocusedIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.requestFocus(widget.initialFocusedIndex!);
      });
    }
  }

  @override
  void didUpdateWidget(covariant InfiniteListSelector oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Update focus if initialFocusedIndex changed
    if (widget.initialFocusedIndex != oldWidget.initialFocusedIndex &&
        widget.initialFocusedIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.requestFocus(widget.initialFocusedIndex!);
      });
    }

    // Reset to first item when widget rebuilds (e.g., filter changes)
    if (widget.autoActivateKeyboard && widget.initialFocusedIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.requestFocus(widget.initialFocusedIndex!);
      });
    }
  }

  @override
  void dispose() {
    controller.removeListener(_handleFocusChange);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, controller);
  }

  void _handleFocusChange() {
    widget.onSelectionChanged?.call(controller.lastFocusedIndex);
  }
}

typedef ItemBuilder =
    Widget? Function(
      BuildContext context,
      int index,
      FocusNode focusNode, {
      int? reorderableIndex,
    });
typedef ItemFetcher = Future<void> Function(int first, int count);

class InfiniteList extends StatefulWidget {
  final ItemBuilder builder;
  final ItemFetcher? fetcher;
  final int count;

  final bool doneEnd;
  final int estimatedItemExtent;

  /// Minimum number of pages to load before and after the current view.
  final double overflow;
  final ScrollController? scrollController;
  final PageStorageKey<String>? scrollStorageKey;
  final InfiniteListController controller;
  final bool reverse;

  /// Callback to enable reordering of items. Returns a callback that will be
  /// invoked when the item is reordered with the new index as parameter.
  final void Function(int newIndex)? Function(int index)? onReorder;

  /// Number of items at the start of the list that are not reorderable.
  /// These items are rendered in a separate sliver so they won't shift
  /// during reorder operations. Only used when [onReorder] is non-null.
  final int nonReorderablePrefixCount;

  /// Builds a separator widget above item[index].
  /// Called for index 0..count-1.
  final Widget Function(BuildContext context, int index)? separatorBuilder;

  InfiniteList({
    required this.builder,
    required this.count,
    this.fetcher,
    bool? doneEnd,
    this.scrollController,
    this.scrollStorageKey,
    this.estimatedItemExtent = 75,
    this.overflow = 2,
    this.reverse = false,
    this.onReorder,
    this.nonReorderablePrefixCount = 0,
    this.separatorBuilder,
    InfiniteListController? controller,
    super.key,
  }) : doneEnd = doneEnd ?? fetcher == null,
       controller = controller ?? InfiniteListController();

  @override
  InfiniteListState createState() => InfiniteListState();
}

class InfiniteListState extends State<InfiniteList> {
  final GlobalKey _listKey = GlobalKey();

  late final ScrollController _scrollController;

  bool _fetching = false;

  (int, int) estimateVisibleIndexes() {
    if (!_scrollController.hasClients ||
        _scrollController.position.viewportDimension <= 0) {
      return (0, 0);
    }
    final totalItems = widget.count;
    if (totalItems == 0) return (0, 0);
    final averageItemExtent =
        _scrollController.position.extentTotal / totalItems;
    var first = (_scrollController.offset / averageItemExtent).floor();
    var last =
        ((_scrollController.offset +
                    _scrollController.position.viewportDimension) /
                averageItemExtent)
            .floor();
    if (first < 0) {
      last += -first;
      first = 0;
    }
    if (last >= widget.count) {
      first = max(first - (last - (widget.count - 1)), 0);
      last = widget.count - 1;
    }
    return (first, last);
  }

  Future<void> _loadIfNecessary() async {
    if (_fetching) {
      return;
    }
    if (!_scrollController.hasClients) return;

    final (firstVisible, lastVisible) = estimateVisibleIndexes();
    final pageSize = lastVisible - firstVisible + 1;

    // Check if we have enough buffer at the end
    final pagesAfter = (widget.count - 1 - lastVisible) / pageSize;

    if (widget.doneEnd || pagesAfter >= widget.overflow) {
      return;
    }

    // Determine scroll direction
    final scrollingUp =
        _scrollController.position.userScrollDirection ==
        ScrollDirection.forward;
    final scrollingDown =
        _scrollController.position.userScrollDirection ==
        ScrollDirection.reverse;

    final newFirst =
        (firstVisible - pageSize * widget.overflow * (scrollingUp ? 1.5 : 1))
            .floor();
    final newCount =
        (pageSize *
                (widget.overflow * (scrollingUp || scrollingDown ? 2.5 : 2) +
                    1))
            .ceil();

    log.info(
      'InfiniteList loading more items: '
      'newFirst=$newFirst, newCount=$newCount, pageSize=$pageSize',
    );

    try {
      _fetching = true;
      await widget.fetcher!(newFirst, newCount);
    } catch (error, trace) {
      log.warning('InfiniteList fetcher error', error, trace);
    } finally {
      // Always reset fetching state when fetch is complete, even if no state update occurs
      if (mounted) {
        setState(() {
          _fetching = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController = widget.scrollController ?? ScrollController();

    // Call _loadIfNecessary on the first frame after initial render
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.clamp(0, widget.count - 1);
      _loadIfNecessary();
    });
  }

  @override
  void dispose() {
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant InfiniteList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onReorder != null && oldWidget.count != widget.count) {
      log.info(
        '[InfiniteList.didUpdateWidget] count=${oldWidget.count}->${widget.count}',
      );
    }
    if (oldWidget.count == widget.count &&
        oldWidget.doneEnd == widget.doneEnd) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.clamp(0, widget.count - 1);
      _loadIfNecessary();
    });
  }

  /// The number of items at the start rendered in a separate non-reorderable
  /// sliver. Zero when reordering is disabled.
  int get _prefixCount =>
      widget.onReorder != null ? widget.nonReorderablePrefixCount : 0;

  /// Builds a non-reorderable sliver for the first [_prefixCount] items.
  SliverList _buildFixedPrefix() {
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index < 0 || index >= widget.count) {
          return SizedBox(key: ValueKey('empty_$index'), height: 0);
        }

        final focusNode = widget.controller.getFocusNode(index);
        final child = widget.builder(context, index, focusNode);

        if (child == null) {
          return SizedBox(key: ValueKey('empty_$index'), height: 0);
        }

        final separator = widget.separatorBuilder?.call(context, index);

        return MouseRegion(
          key: ValueKey('item_$index'),
          onEnter: (_) => widget.controller.setHovered(index),
          onExit: (_) => widget.controller.setHovered(null),
          child: separator != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [separator, child],
                )
              : child,
        );
      }, childCount: _prefixCount),
    );
  }

  SliverReorderableList _buildSliverList() {
    final offset = _prefixCount;
    final count = widget.count - offset;

    return SliverReorderableList(
      key: _listKey,
      itemCount: count,
      itemBuilder: (context, reorderIndex) {
        final index = reorderIndex + offset;
        if (index < 0 || index >= widget.count) {
          return SizedBox(key: ValueKey('empty_$index'), height: 0);
        }

        // Get or create FocusNode for this item
        final focusNode = widget.controller.getFocusNode(index);
        final onReorder = widget.onReorder?.call(index);

        // Pass reorderableIndex to builder if reordering is enabled.
        // Must use reorderIndex (position within this SliverReorderableList),
        // not the original index, so ReorderableDragStartListener picks up
        // the correct item.
        var child = widget.builder(
          context,
          index,
          focusNode,
          reorderableIndex: onReorder != null ? reorderIndex : null,
        );

        if (child == null) {
          return SizedBox(key: ValueKey('empty_$index'), height: 0);
        }

        final separator = widget.separatorBuilder?.call(context, index);

        // Wrap with MouseRegion to track hover state
        // Key is required by SliverReorderableList on the outermost widget
        return MouseRegion(
          key: ValueKey('item_$index'),
          onEnter: (_) => widget.controller.setHovered(index),
          onExit: (_) => widget.controller.setHovered(null),
          child: separator != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [separator, child],
                )
              : child,
        );
      },
      onReorderStart: (reorderIndex) {
        widget.controller.setDragging(reorderIndex + offset);
      },
      onReorderEnd: (_) {
        widget.controller.setDragging(null);
      },
      proxyDecorator: (child, reorderIndex, animation) {
        final nextIndex = reorderIndex + offset + 1;
        final bottomSeparator = nextIndex < widget.count
            ? widget.separatorBuilder?.call(context, nextIndex)
            : null;
        if (bottomSeparator != null) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [child, bottomSeparator],
          );
        }
        return child;
      },
      onReorder: (oldReorderIndex, newReorderIndex) {
        final adjustedNewIndex = newReorderIndex > oldReorderIndex
            ? newReorderIndex - 1
            : newReorderIndex;
        log.info(
          '[InfiniteList.onReorder] old=$oldReorderIndex new=$adjustedNewIndex '
          'count=$count offset=$offset',
        );
        final onReorder = widget.onReorder?.call(oldReorderIndex + offset);
        onReorder?.call(adjustedNewIndex + offset);
        log.info('[InfiniteList.onReorder] parent callback returned');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const spinner = SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0),
        child: Center(child: Spinner()),
      ),
    );

    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification is ScrollUpdateNotification) {
          _loadIfNecessary();
        }
        return false;
      },
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, child) => ScrollConfiguration(
          behavior: const ScrollBehavior().copyWith(scrollbars: false),
          child: CustomScrollView(
            key: widget.scrollStorageKey,
            controller: _scrollController,
            reverse: widget.reverse,
            slivers: [
              if (_prefixCount > 0) _buildFixedPrefix(),
              _buildSliverList(),
              if (!widget.doneEnd) spinner,
            ],
          ),
        ),
      ),
    );
  }
}
