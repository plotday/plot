import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/action/base.dart' hide Action, Actions;
import 'logging.dart';

class BidirectionalListController extends ChangeNotifier {
  BidirectionalListController({
    int? initialSelected,
    int initialMin = 0,
    int initialMax = 0,
  }) : _min = initialMin,
       _max = initialMax,
       _keyboardPosition = initialSelected;

  int? _keyboardPosition;
  int? _hoveredIndex;
  bool _keyboardActive = false;
  int _min;
  int _max;

  int? get hoveredIndex => _hoveredIndex;

  /// Returns the index that should be highlighted.
  /// Only shows highlight during active interaction (keyboard or mouse).
  /// Prioritizes hover (mouse) over keyboard selection.
  int? get highlighted =>
      _hoveredIndex ?? (_keyboardActive ? _keyboardPosition : null);

  void _setKeyboardPosition(int? value) {
    if (value != null && value < _min) {
      value = _min;
    }
    if (value != null && value > _max) {
      value = _max;
    }
    if (_keyboardPosition != value) {
      _keyboardPosition = value;
      notifyListeners();
    }
  }

  void setSelected(int? value) {
    _setKeyboardPosition(value);
  }

  void clamp(int min, int max) {
    _min = min;
    _max = max;
    if (_keyboardPosition != null && _keyboardPosition! < _min) {
      _setKeyboardPosition(_min);
    }
    if (_keyboardPosition != null && _keyboardPosition! > _max) {
      _setKeyboardPosition(_max);
    }
  }

  void move(int offset) {
    // Clear hover when using keyboard navigation
    _hoveredIndex = null;

    // If keyboard not yet active, just activate and show current position
    if (!_keyboardActive) {
      _keyboardActive = true;
      // Initialize keyboard position if null
      _keyboardPosition ??= 0;
      // Don't move - just show highlight on current item
      notifyListeners();
      return;
    }

    // Keyboard already active - navigate normally
    if (_keyboardPosition == null) {
      _setKeyboardPosition(0);
    } else {
      _setKeyboardPosition(_keyboardPosition! + offset);
    }
  }

  void setHovered(int? index) {
    if (_hoveredIndex != index) {
      _hoveredIndex = index;
      // Clear keyboard active mode when mouse interaction starts
      if (index != null) {
        _keyboardActive = false;
      }
      notifyListeners();
    }
  }

  void clear() {
    _setKeyboardPosition(null);
  }
}

class ActivateListSelectionIntent extends Intent {
  const ActivateListSelectionIntent();
}

class MoveListSelectionIntent extends Intent {
  const MoveListSelectionIntent(this.offset);
  final int offset;
}

class BidirectionalListSelector extends StatefulWidget {
  final Widget Function(
    BuildContext context,
    BidirectionalListController controller,
  )
  builder;

  final ValueChanged<int?>? onSelectionChanged;
  final void Function(int)? onActivate;
  final bool reverse;
  final bool autoActivateKeyboard;
  final int? initialHighlight;

  const BidirectionalListSelector({
    super.key,
    required this.builder,
    this.onSelectionChanged,
    this.onActivate,
    this.reverse = false,
    this.autoActivateKeyboard = false,
    this.initialHighlight,
  });

  @override
  BidirectionalListSelectorState createState() =>
      BidirectionalListSelectorState();
}

class BidirectionalListSelectorState extends State<BidirectionalListSelector> {
  late final BidirectionalListController controller =
      BidirectionalListController(initialSelected: widget.initialHighlight);

  @override
  void initState() {
    super.initState();
    controller.addListener(_handleSelectionChange);

    // Auto-activate keyboard mode if requested or if there's an initial selection
    if (widget.autoActivateKeyboard || widget.initialHighlight != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.move(0);
      });
    }
  }

  @override
  void didUpdateWidget(covariant BidirectionalListSelector oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Update selection if initialSelected changed
    if (widget.initialHighlight != oldWidget.initialHighlight) {
      controller.setSelected(widget.initialHighlight);
    }

    // Reset to first item when widget rebuilds (e.g., filter changes)
    if (widget.autoActivateKeyboard) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.move(0);
      });
    }
  }

  @override
  void dispose() {
    controller.removeListener(_handleSelectionChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateListSelectionIntent:
            CallbackAction<ActivateListSelectionIntent>(
              onInvoke: (intent) {
                if (controller.highlighted == null) {
                  return KeyEventResult.ignored;
                }
                widget.onActivate?.call(controller.highlighted!);
                return KeyEventResult.handled;
              },
            ),
        MoveListSelectionIntent: CallbackAction<MoveListSelectionIntent>(
          onInvoke: (intent) {
            controller.move((widget.reverse ? 1 : -1) * intent.offset);
            return KeyEventResult.handled;
          },
        ),
      },
      child: widget.builder(context, controller),
    );
  }

  void _handleSelectionChange() {
    widget.onSelectionChanged?.call(controller.highlighted);
  }
}

typedef ItemBuilder =
    Widget? Function(BuildContext context, int index, bool selected);
typedef ItemFetcher = Future<void> Function(int first, int count);

class BidirectionalList extends StatefulWidget {
  static const Map<ShortcutActivator, Intent> shortcuts = {
    SingleActivator(LogicalKeyboardKey.enter, shift: false):
        ActivateListSelectionIntent(),
    SingleActivator(LogicalKeyboardKey.arrowUp): MoveListSelectionIntent(1),
    SingleActivator(LogicalKeyboardKey.arrowDown): MoveListSelectionIntent(-1),
  };

  final ItemBuilder builder;
  final ItemFetcher? fetcher;
  final int count;

  /// index of the first item
  final int first;

  /// the item at the 0 index is at the anchorOffset position in the initial view
  final double anchorOffset;
  final bool doneStart;
  final bool doneEnd;
  final int estimatedItemExtent;

  /// Minimum number of pages to load before and after the current view.
  final double overflow;
  final ScrollController? scrollController;
  final BidirectionalListController controller;
  final bool reverse;
  final void Function(int newIndex)? Function(int index)? onReorder;

  BidirectionalList({
    required this.builder,
    required this.count,
    this.fetcher,
    this.first = 0,
    this.anchorOffset = 0,
    bool? doneStart,
    bool? doneEnd,
    this.scrollController,
    this.estimatedItemExtent = 75,
    this.overflow = 2,
    this.reverse = false,
    this.onReorder,
    BidirectionalListController? controller,
    super.key,
  }) : doneStart = doneStart ?? fetcher == null,
       doneEnd = doneEnd ?? fetcher == null,
       controller = controller ?? BidirectionalListController();

  @override
  BidirectionalListState createState() => BidirectionalListState();
}

class BidirectionalListState extends State<BidirectionalList> {
  final GlobalKey _upListKey = GlobalKey();
  final GlobalKey _downListKey = GlobalKey();

  late final ScrollController _scrollController;

  bool _fetching = false;

  late int _upCount;
  late int _downCount;

  void _setCounts() {
    _upCount = max(-widget.first, 0);
    _downCount = max(widget.first + widget.count, 0);
    log.info(
      'BidirectionalList counts set: upCount=$_upCount, downCount=$_downCount, first=${widget.first}, count=${widget.count}',
    );
  }

  (int, int) estimateVisibleIndexes() {
    if (!_scrollController.hasClients ||
        _scrollController.position.viewportDimension <= 0) {
      return (0, 0);
    }
    final totalItems =
        max(-widget.first, 0) + max(widget.first + widget.count, 0);
    final averageItemExtent =
        _scrollController.position.extentTotal / totalItems;
    var first = min(
      (_scrollController.offset / averageItemExtent).floor(),
      widget.first +
          ((_scrollController.position.pixels -
                      _scrollController.position.minScrollExtent) /
                  averageItemExtent)
              .floor(),
    );
    var last =
        ((_scrollController.offset +
                    _scrollController.position.viewportDimension) /
                averageItemExtent)
            .floor();
    if (first < widget.first) {
      last += (widget.first - first);
      first = widget.first;
    }
    if (last >= widget.first + widget.count) {
      first = max(
        first - (last - (widget.first + widget.count - 1)),
        widget.first,
      );
      last = widget.first + widget.count - 1;
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

    // Check if we have enough buffer
    final pagesBefore = (firstVisible - widget.first) / pageSize;
    final pagesAfter =
        (widget.first + widget.count - 1 - lastVisible) / pageSize;

    if ((widget.doneStart || pagesBefore >= widget.overflow) &&
        (widget.doneEnd || pagesAfter >= widget.overflow)) {
      // We have all or enough
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
      'BidirectionalList loading more items: '
      'newFirst=$newFirst, newCount=$newCount, pageSize=$pageSize',
    );

    try {
      _fetching = true;
      await widget.fetcher!(newFirst, newCount);
    } catch (error, trace) {
      log.warning('BidirectionalList fetcher error', error, trace);
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
    _setCounts();
    _scrollController = widget.scrollController ?? ScrollController();

    // Call _loadIfNecessary on the first frame after initial render
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.clamp(widget.first, widget.first + widget.count - 1);
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
  void didUpdateWidget(covariant BidirectionalList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.first == widget.first &&
        oldWidget.count == widget.count &&
        oldWidget.doneStart == widget.doneStart &&
        oldWidget.doneEnd == widget.doneEnd) {
      return;
    }

    setState(() {
      _setCounts();
      if (oldWidget.first != widget.first) {
        log.info('First moved ${oldWidget.first} to ${widget.first}');
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.clamp(widget.first, widget.first + widget.count - 1);
      _loadIfNecessary();
    });
  }

  SliverReorderableList _buildSliverList({
    required GlobalKey key,
    required int itemCount,
    required int? Function(int index) itemIndexCalculator,
  }) {
    return SliverReorderableList(
      key: key,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final itemIndex = itemIndexCalculator(index);
        if (itemIndex == null) {
          return SizedBox(key: ValueKey('empty_$index'), height: 0);
        }
        final isHighlighted = itemIndex == widget.controller.highlighted;
        var child = widget.builder(context, itemIndex, isHighlighted);

        if (child == null) {
          return SizedBox(key: ValueKey('empty_$itemIndex'), height: 0);
        }

        final onReorder = widget.onReorder?.call(itemIndex);

        // Wrap with MouseRegion to track hover state
        // Key is required by SliverReorderableList on the outermost widget
        child = MouseRegion(
          key: onReorder == null ? ValueKey('item_$itemIndex') : null,
          onEnter: (_) => widget.controller.setHovered(itemIndex),
          onExit: (_) => widget.controller.setHovered(null),
          child: child,
        );

        if (onReorder != null) {
          return ReorderableDragStartListener(
            index: index,
            key: ValueKey('item_$itemIndex'),
            child: child,
          );
        }
        return child;
      },
      onReorder: (oldIndex, newIndex) {
        final onReorder = widget.onReorder?.call(
          itemIndexCalculator(oldIndex)!,
        );
        final index = itemIndexCalculator(
          newIndex > oldIndex ? newIndex - 1 : newIndex,
        );
        assert(
          index != null,
          'Item index calculator returned null for new index: $newIndex',
        );
        onReorder?.call(index!);
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
        builder: (context, child) => CustomScrollView(
          controller: _scrollController,
          center: _downListKey,
          anchor: widget.anchorOffset,
          reverse: widget.reverse,
          slivers: [
            if (widget.count > 0 && !widget.doneStart) spinner,
            _buildSliverList(
              key: _upListKey,
              itemCount: _upCount,
              // itemIndexCalculator: (index) =>
              //     widget.first + _upCount - index - 1,
              itemIndexCalculator: (index) {
                index = -index - 1;
                if (index >= widget.first &&
                    index < widget.first + widget.count) {
                  return index;
                }
                return null;
              },
            ),
            _buildSliverList(
              key: _downListKey,
              itemCount: _downCount,
              itemIndexCalculator: (index) {
                if (index >= widget.first &&
                    index < widget.first + widget.count) {
                  return index;
                }
                return null;
              },
            ),
            if (!widget.doneEnd) spinner,
          ],
        ),
      ),
    );
  }
}

class SelectionActionScope extends StatefulWidget {
  const SelectionActionScope({
    required this.actionBuilder,
    required this.listController,
    required this.child,
    super.key,
  });

  final List<StaticActionGroup> Function(int index) actionBuilder;
  final BidirectionalListController listController;
  final Widget child;

  @override
  SelectionActionScopeState createState() => SelectionActionScopeState();
}

class SelectionActionScopeState extends State<SelectionActionScope> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.listController,
      builder: (context, child) => ActionScope(
        actions: [
          if (widget.listController.highlighted != null)
            ...widget.actionBuilder(widget.listController.highlighted!),
        ],
        child: widget.child,
      ),
    );
  }
}
