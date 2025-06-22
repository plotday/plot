import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/command/base.dart';
import 'logging.dart';

class BidirectionalListController extends ChangeNotifier {
  BidirectionalListController({
    int? initialSelected,
    int initialMin = 0,
    int initialMax = 0,
  }) : _min = initialMin,
       _max = initialMax,
       _selected = initialSelected;

  int? _selected;
  int _min;
  int _max;

  int? get selected => _selected;

  set selected(int? value) {
    if (value != null && value < _min) {
      value = _min;
    }
    if (value != null && value > _max) {
      value = _max;
    }
    if (_selected != value) {
      _selected = value;
      notifyListeners();
    }
  }

  void clamp(int min, int max) {
    _min = min;
    _max = max;
    if (_selected != null && _selected! < _min) {
      selected = _min;
    }
    if (_selected != null && _selected! > _max) {
      selected = _max;
    }
  }

  void move(int offset) {
    if (selected == null) {
      selected = 0;
    } else {
      selected = selected! + offset;
    }
  }

  void clear() {
    selected = null;
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

  const BidirectionalListSelector({
    super.key,
    required this.builder,
    this.onSelectionChanged,
    this.onActivate,
    this.reverse = false,
  });

  @override
  BidirectionalListSelectorState createState() =>
      BidirectionalListSelectorState();
}

class BidirectionalListSelectorState extends State<BidirectionalListSelector> {
  late final BidirectionalListController controller =
      BidirectionalListController(initialSelected: 0);

  @override
  void initState() {
    super.initState();
    controller.addListener(_handleSelectionChange);
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
                if (controller.selected == null) {
                  return KeyEventResult.ignored;
                }
                widget.onActivate?.call(controller.selected!);
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
    widget.onSelectionChanged?.call(controller.selected);
  }
}

typedef ItemBuilder =
    Widget? Function(BuildContext context, int index, bool selected);
typedef ItemFetcher = void Function(int first, int count);

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

  /// the item at this index is at the anchorOffset position in the initial view
  final int anchor;
  final double anchorOffset;
  final bool doneStart;
  final bool doneEnd;
  final int estimatedItemExtent;

  /// Minimum number of pages to load before and after the current view.
  final double overflow;
  final ScrollController? scrollController;
  final BidirectionalListController controller;
  final bool reverse;
  final ReorderCallback? onReorder;

  BidirectionalList({
    required this.builder,
    required this.count,
    this.fetcher,
    this.first = 0,
    this.anchor = 0,
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

  // Prevent the list from growing on the first frame in order to calculate the
  // amount of shrinkage, which is used to adjust the scroll position.
  int _shrinkUp = 0;
  int _shrinkDown = 0;
  late int _upCount;
  late int _downCount;
  late double _averageItemExtent = widget.estimatedItemExtent.toDouble();
  (double?, double?) _lastListExtents = (null, null);

  void _setCounts() {
    assert(
      widget.count == 0 ||
          (widget.anchor >= widget.first &&
              widget.anchor < widget.first + widget.count),
      'Anchor must be a valid index',
    );
    _upCount = max(widget.anchor - widget.first, 0);
    _downCount = max(widget.count - _upCount, 0);
  }

  (double?, double?) get _listExtents => (
    (_upListKey.currentContext?.findRenderObject() as RenderSliverList?)
        ?.geometry
        ?.scrollExtent,
    (_downListKey.currentContext?.findRenderObject() as RenderSliverList?)
        ?.geometry
        ?.scrollExtent,
  );

  // Only call in a post-frame callback when the lists are rendered for the
  // given counts.
  void _updateAverageItemExtent() {
    final (upExtent, downExtent) = _listExtents;
    var count = 0;
    double extent = 0;
    if (_downCount > 0 && (downExtent ?? 0) > 0) {
      extent += downExtent!;
      count += _downCount;
    }
    if (_upCount > 0 && (upExtent ?? 0) > 0) {
      extent += upExtent!;
      count += _upCount;
    }
    if (count > 0 && extent > 0) {
      final newAverage = extent / count;
      // Ensure we don't set an extremely small or zero average that could cause issues
      if (newAverage > 0.1) {
        _averageItemExtent = newAverage;
      }
    }
  }

  double _getScrollAdjustment() {
    final (up, down) = _listExtents;
    final (lastUp, lastDown) = _lastListExtents;
    var move = 0.0;
    // We need to adjust the position only when either list removes items from
    // their start. We detect this by checking if they have shrunk before new
    // items are added.
    if (_shrinkUp != 0 && lastUp != null && up != null && up < lastUp) {
      move += lastUp - up;
    }
    if (_shrinkDown != 0 &&
        lastDown != null &&
        down != null &&
        down < lastDown) {
      move += down - lastDown;
    }
    _lastListExtents = (up, down);
    return move;
  }

  double averageItemsPerPage() {
    // Prevent division by zero and ensure scroll controller is ready
    if (!_scrollController.hasClients || _averageItemExtent <= 0) {
      return 1.0; // Fallback to 1 item per page
    }
    return _scrollController.position.viewportDimension / _averageItemExtent;
  }

  double pagesBefore() {
    if (!_scrollController.hasClients ||
        _scrollController.position.viewportDimension <= 0) {
      return 0.0;
    }
    return (_scrollController.position.pixels -
            _scrollController.position.minScrollExtent) /
        _scrollController.position.viewportDimension;
  }

  double pagesAfter() {
    if (!_scrollController.hasClients ||
        _scrollController.position.viewportDimension <= 0) {
      return 0.0;
    }
    return (_scrollController.position.maxScrollExtent -
            _scrollController.position.pixels) /
        _scrollController.position.viewportDimension;
  }

  Future<void> _loadIfNecessary() async {
    if (_fetching) return;
    if (widget.doneStart && widget.doneEnd) return;
    if (!_scrollController.hasClients) return;

    // Check if we have enough buffer
    if (pagesBefore() >= widget.overflow && pagesAfter() >= widget.overflow) {
      return;
    }

    // Determine scroll direction
    bool scrollingUp =
        _scrollController.position.userScrollDirection ==
        ScrollDirection.forward;
    bool scrollingDown =
        _scrollController.position.userScrollDirection ==
        ScrollDirection.reverse;

    // Calculate how many items we need to fetch
    final itemsPerPage = averageItemsPerPage();
    int itemsToFetchBefore = 0;
    int itemsToFetchAfter = 0;

    // Only fetch in the direction we're scrolling or if we're below the threshold
    if (pagesBefore() < widget.overflow && !widget.doneStart) {
      final targetPages = widget.overflow * (scrollingUp ? 1.5 : 1);
      itemsToFetchBefore = ((targetPages - pagesBefore()) * itemsPerPage)
          .ceil();
    }

    if (pagesAfter() < widget.overflow && !widget.doneEnd) {
      final targetPages = widget.overflow * (scrollingDown ? 1.5 : 1);
      itemsToFetchAfter = ((targetPages - pagesAfter()) * itemsPerPage).ceil();
    }

    if (itemsToFetchBefore > 0 || itemsToFetchAfter > 0) {
      _loadMoreItems(itemsToFetchBefore, itemsToFetchAfter);
    }
  }

  Future<void> _loadMoreItems(int itemsBefore, int itemsAfter) async {
    if (widget.fetcher == null || _fetching) return;

    // Calculate the new range
    final newFirst = widget.first - itemsBefore;
    final newCount = widget.count + itemsBefore + itemsAfter;

    try {
      _fetching = true;

      // Call the fetcher with the new range
      widget.fetcher!(newFirst, newCount);
    } catch (error) {
      debugPrint('BidirectionalList fetcher error: $error');
    }
  }

  @override
  void initState() {
    super.initState();
    _setCounts();
    _scrollController = widget.scrollController ?? ScrollController();
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
        oldWidget.doneEnd == widget.doneEnd &&
        oldWidget.anchor == widget.anchor) {
      return;
    }

    setState(() {
      _fetching = false;
      _setCounts();
      widget.controller.clamp(widget.first, widget.first + widget.count - 1);
      if (oldWidget.anchor == widget.anchor) {
        int moveUp = widget.first - oldWidget.first;
        int moveDown = oldWidget.count - widget.count - moveUp;
        _shrinkUp = max(0, moveUp);
        _shrinkDown = max(0, moveDown);
        log.info(
          'BidirectionalList: moveUp=$moveUp, moveDown=$moveDown, shrinkUp=$_shrinkUp, shrinkDown=$_shrinkDown',
        );
        if (widget.controller.selected != null) {
          widget.controller.move(moveUp);
        }
      } else {
        log.info('Anchor ${oldWidget.anchor} changed to ${widget.anchor}');
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        _shrinkUp = 0;
        _shrinkDown = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateAverageItemExtent();
      });
    });
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
          physics: BidirectionalListScrollPhysics(
            getScrollAdjustment: _getScrollAdjustment,
          ),
          center: _downListKey,
          anchor: widget.anchorOffset,
          reverse: widget.reverse,
          slivers: [
            if (widget.count > 0 && !widget.doneStart) spinner,
            SliverReorderableList(
              key: _upListKey,
              itemCount: _upCount - _shrinkUp,
              itemBuilder: (context, index) {
                final itemIndex =
                    widget.first + _upCount - _shrinkUp - index - 1;
                final isSelected = itemIndex == widget.controller.selected;
                final child = widget.builder(context, itemIndex, isSelected);
                return child ??
                    SizedBox(key: ValueKey('empty_$itemIndex'), height: 0);
              },
              onReorder: (oldIndex, newIndex) {
                widget.onReorder?.call(
                  widget.first + _upCount - _shrinkUp - oldIndex - 1,
                  widget.first + _upCount - _shrinkUp - newIndex - 1,
                );
              },
            ),
            SliverReorderableList(
              key: _downListKey,
              itemCount: _downCount - _shrinkDown,
              itemBuilder: (context, index) {
                final itemIndex = widget.first + _upCount + index;
                final isSelected = itemIndex == widget.controller.selected;
                final child = widget.builder(context, itemIndex, isSelected);
                return child ??
                    SizedBox(key: ValueKey('empty_$itemIndex'), height: 0);
              },
              onReorder: (oldIndex, newIndex) {
                widget.onReorder?.call(
                  widget.first + _upCount + oldIndex,
                  widget.first + _upCount + newIndex,
                );
              },
            ),
            if (!widget.doneEnd) spinner,
          ],
        ),
      ),
    );
  }
}

// Apply the position adjustment after layout
class BidirectionalListScrollPhysics extends ScrollPhysics {
  final double Function() getScrollAdjustment;

  const BidirectionalListScrollPhysics({
    required this.getScrollAdjustment,
    super.parent,
  });

  @override
  BidirectionalListScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return BidirectionalListScrollPhysics(
      getScrollAdjustment: getScrollAdjustment,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final double unadjustedPosition = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    return unadjustedPosition + getScrollAdjustment();
  }
}

class SelectionCommandScope extends StatefulWidget {
  const SelectionCommandScope({
    required this.commandBuilder,
    required this.listController,
    required this.child,
    super.key,
  });

  final List<StaticCommandGroup> Function(int index) commandBuilder;
  final BidirectionalListController listController;
  final Widget child;

  @override
  SelectionCommandScopeState createState() => SelectionCommandScopeState();
}

class SelectionCommandScopeState extends State<SelectionCommandScope> {
  @override
  Widget build(BuildContext context) {
    return CommandScope(
      commands: [
        if (widget.listController.selected != null)
          ...widget.commandBuilder(widget.listController.selected!),
      ],
      child: widget.child,
    );
  }
}
