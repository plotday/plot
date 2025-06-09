import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:plot/widget/widget.dart';

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
                  KeyEventResult.ignored;
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
typedef ItemFetcher = Future<void> Function(int move, int count);

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
  // index of the item in the list that should be centred in the initial view
  // TODO: support positioing the anchor at other other positions
  final int anchor;
  // arbitrary, relative value representing the position of the first item in
  // the list
  final int offset;
  final bool doneStart;
  final bool doneEnd;
  final int estimatedItemExtent;
  final double overflow;
  final ScrollController? scrollController;
  final BidirectionalListController controller;
  final bool reverse;
  final ReorderCallback? onReorder;

  BidirectionalList({
    required this.builder,
    required this.count,
    this.fetcher,
    this.anchor = 0,
    this.offset = 0,
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

  bool _loading = false;
  // Prevent the list from growing on the first frame in order to calculate the
  // amount of shrinkage, which is used to adjust the scroll position.
  int _shrinkUp = 0;
  int _shrinkDown = 0;
  late int _upCount = widget.anchor;
  late int _downCount = widget.count - widget.anchor;
  late double _averageItemExtent = widget.estimatedItemExtent.toDouble();
  (double?, double?) _lastListExtents = (null, null);

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
      _averageItemExtent = extent / count;
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
    return _scrollController.position.viewportDimension / _averageItemExtent;
  }

  double pagesBefore() {
    return (_scrollController.position.pixels -
            _scrollController.position.minScrollExtent) /
        _scrollController.position.viewportDimension;
  }

  double pagesAfter() {
    return (_scrollController.position.maxScrollExtent -
            _scrollController.position.pixels) /
        _scrollController.position.viewportDimension;
  }

  Future<void> _loadIfNecessary() async {
    if (_loading) return;
    if (widget.doneStart && widget.doneEnd) return;
    if (pagesBefore() >= widget.overflow && pagesAfter() >= widget.overflow) {
      return;
    }
    bool scrollingUp =
        _scrollController.position.userScrollDirection ==
        ScrollDirection.forward;
    bool scrollingDown =
        _scrollController.position.userScrollDirection ==
        ScrollDirection.reverse;
    final moveUp =
        ((widget.overflow * (scrollingUp ? 1.5 : 1) - pagesBefore()) *
                averageItemsPerPage())
            .ceil();
    final moveDown =
        ((widget.overflow * (scrollingDown ? 1.5 : 1) - pagesAfter()) *
                averageItemsPerPage())
            .ceil();
    _loadMoreItems(moveUp, moveDown);
  }

  Future<void> _loadMoreItems(int moveUp, int moveDown) async {
    if (widget.fetcher == null || _loading) return;
    try {
      _loading = true;
      await widget.fetcher!(-moveUp, widget.count + moveUp + moveDown);
    } finally {
      _loading = false;
    }
  }

  @override
  void initState() {
    super.initState();
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
    if (oldWidget.anchor != widget.anchor) {
      _upCount = widget.anchor;
      _downCount = widget.count - widget.anchor;
    }
    if (oldWidget.offset == widget.offset && oldWidget.count == widget.count) {
      return;
    }
    int moveUp = widget.offset - oldWidget.offset;
    int moveDown = widget.count - oldWidget.count - moveUp;
    setState(() {
      _shrinkUp = max(0, moveUp);
      _shrinkDown = max(0, moveDown);
      // TODO handle the ends of lists
      _upCount = min(max(_upCount + moveUp, 0), widget.count);
      _downCount = min(max(_downCount + moveDown, 0), widget.count);
      widget.controller.clamp(
        -(widget.count - _downCount),
        widget.count - _upCount,
      );
      if (widget.controller.selected != null) {
        widget.controller.move(widget.offset - oldWidget.offset);
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

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification notification) {
        _loadIfNecessary();
        return false; // Return false to allow the notification to continue to be dispatched
      },
      child: ListenableBuilder(
        listenable: widget.controller,
        builder:
            (context, child) => CustomScrollView(
              controller: _scrollController,
              physics: BidirectionalListScrollPhysics(
                getScrollAdjustment: _getScrollAdjustment,
              ),
              center: _downListKey,
              reverse: widget.reverse,
              slivers: [
                if (widget.count > 0 && !widget.doneStart) spinner,
                SliverReorderableList(
                  key: _upListKey,
                  itemCount: _upCount - _shrinkUp,
                  itemBuilder:
                      (context, index) =>
                          widget.builder(
                            context,
                            _upCount - index - 1,
                            index == widget.controller.selected,
                          ) ??
                          Container(),
                  onReorder: (oldIndex, newIndex) {
                    widget.onReorder?.call(
                      _upCount - oldIndex - 1,
                      _upCount - newIndex - 1,
                    );
                  },
                ),
                SliverReorderableList(
                  key: _downListKey,
                  itemCount: _downCount - _shrinkDown,
                  itemBuilder:
                      (context, index) =>
                          widget.builder(
                            context,
                            _upCount + index,
                            index == widget.controller.selected,
                          ) ??
                          Container(),
                  onReorder: (oldIndex, newIndex) {
                    widget.onReorder?.call(
                      _upCount + oldIndex,
                      _upCount + newIndex,
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
