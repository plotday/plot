import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:plot/widget/widget.dart';

class ItemFetchResult {
  final int count;
  final bool doneStart;
  final bool doneEnd;

  const ItemFetchResult({
    required this.count,
    this.doneStart = false,
    this.doneEnd = false,
  });
}

typedef ItemBuilder = Widget? Function(BuildContext context, int index);
typedef ItemFetcher = Future<ItemFetchResult> Function(int move, int count);

class BidirectionalList extends StatefulWidget {
  final ItemBuilder builder;
  final ItemFetcher fetcher;
  final int estimatedItemExtent; // used to calculate the initial fetch
  final double overflow; // prefetch at least this multiple of the visible items
  final ScrollController scrollController;
  final bool userProvidedScrollController;

  BidirectionalList({
    required this.builder,
    required this.fetcher,
    ScrollController? scrollController,
    this.estimatedItemExtent = 75,
    this.overflow = 2,
    super.key,
  })  : scrollController = scrollController ?? ScrollController(),
        userProvidedScrollController = scrollController != null;

  @override
  BidirectionalListState createState() => BidirectionalListState();
}

class BidirectionalListState extends State<BidirectionalList> {
  final GlobalKey _upListKey = GlobalKey();
  final GlobalKey _downListKey = GlobalKey();

  bool _loading = false;
  // Prevent the list from growing on the first frame in order to calculate the
  // amount of shrinkage, which is used to adjust the scroll position.
  int _shrinkUp = 0;
  int _shrinkDown = 0;
  int _upCount = 0;
  int _downCount = 0;
  int get _count => _upCount + _downCount;
  bool _doneStart = false;
  bool _doneEnd = false;
  late double _averageItemExtent = widget.estimatedItemExtent.toDouble();
  (double?, double?) _lastListExtents = (null, null);

  (double?, double?) get _listExtents => (
        (_upListKey.currentContext?.findRenderObject() as RenderSliverList?)
            ?.geometry
            ?.scrollExtent,
        (_downListKey.currentContext?.findRenderObject() as RenderSliverList?)
            ?.geometry
            ?.scrollExtent
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
    return widget.scrollController.position.viewportDimension /
        _averageItemExtent;
  }

  double pagesBefore() {
    return (widget.scrollController.position.pixels -
            widget.scrollController.position.minScrollExtent) /
        widget.scrollController.position.viewportDimension;
  }

  double pagesAfter() {
    return (widget.scrollController.position.maxScrollExtent -
            widget.scrollController.position.pixels) /
        widget.scrollController.position.viewportDimension;
  }

  void _loadInitialItems() {
    _loadMoreItems(
        ((widget.scrollController.position.viewportDimension /
                    widget.estimatedItemExtent) *
                widget.overflow)
            .ceil(),
        ((widget.scrollController.position.viewportDimension /
                    widget.estimatedItemExtent) *
                widget.overflow)
            .ceil());
  }

  void _loadIfNecessary() {
    if (_loading) return;
    if (_doneStart && _doneEnd) return;
    if (pagesBefore() >= widget.overflow && pagesAfter() >= widget.overflow) {
      return;
    }
    bool scrollingUp = widget.scrollController.position.userScrollDirection ==
        ScrollDirection.forward;
    bool scrollingDown = widget.scrollController.position.userScrollDirection ==
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
    if (_loading) return;
    _loading = true;
    final result = await widget.fetcher(-moveUp, _count + moveUp + moveDown);
    setState(() {
      _shrinkUp = max(0, moveUp);
      _shrinkDown = max(0, moveDown);
      // TODO handle the ends of lists
      _upCount = min(max(_upCount + moveUp, 0), result.count);
      _downCount = min(max(_downCount + moveDown, 0), result.count);
      _doneStart = result.doneStart;
      _doneEnd = result.doneEnd;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        _loading = false;
        _shrinkUp = 0;
        _shrinkDown = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateAverageItemExtent();
      });
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInitialItems();
      widget.scrollController.addListener(_loadIfNecessary);
    });
  }

  @override
  void dispose() {
    if (!widget.userProvidedScrollController) {
      widget.scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const spinner = SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0),
        child: Center(
          child: Spinner(),
        ),
      ),
    );
    return Scrollable(
      controller: widget.scrollController,
      physics: BidirectionalListScrollPhysics(
        getScrollAdjustment: _getScrollAdjustment,
      ),
      viewportBuilder: (BuildContext context, ViewportOffset position) {
        return Viewport(
          offset: position,
          center: _downListKey,
          slivers: [
            if (_count > 0 && !_doneStart) spinner,
            SliverList.builder(
              key: _upListKey,
              itemCount: _upCount - _shrinkUp,
              itemBuilder: (context, index) =>
                  widget.builder(context, _upCount - index - 1),
            ),
            SliverList.builder(
              key: _downListKey,
              itemCount: _downCount - _shrinkDown,
              itemBuilder: (context, index) =>
                  widget.builder(context, _upCount + index),
            ),
            if (!_doneEnd) spinner,
          ],
        );
      },
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
