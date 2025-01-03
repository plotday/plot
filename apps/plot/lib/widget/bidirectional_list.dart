import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:plot/widget/widget.dart';

typedef ItemBuilder = Widget? Function(BuildContext context, int index);
typedef ItemFetcher = Future<void> Function(int move, int count);

class BidirectionalList extends StatefulWidget {
  final ItemBuilder builder;
  final ItemFetcher? fetcher;
  final int count;
  // arbitrary, relative value representing the position of the first item in
  // the list
  final int offset;
  final bool doneStart;
  final bool doneEnd;
  final int estimatedItemExtent;
  final double overflow;
  final ScrollController? scrollController;
  final Widget? header;

  const BidirectionalList({
    required this.builder,
    required this.count,
    this.fetcher,
    this.offset = 0,
    bool? doneStart,
    bool? doneEnd,
    this.scrollController,
    this.estimatedItemExtent = 75,
    this.overflow = 2,
    this.header,
    super.key,
  })  : doneStart = doneStart ?? fetcher == null,
        doneEnd = doneEnd ?? fetcher == null;

  @override
  BidirectionalListState createState() => BidirectionalListState();
}

class BidirectionalListState extends State<BidirectionalList> {
  final GlobalKey _upListKey = GlobalKey();
  final GlobalKey _downListKey = GlobalKey();
  final GlobalKey _headerKey = GlobalKey();

  late final ScrollController _scrollController;

  bool _loading = false;
  // Prevent the list from growing on the first frame in order to calculate the
  // amount of shrinkage, which is used to adjust the scroll position.
  int _shrinkUp = 0;
  int _shrinkDown = 0;
  late int _upCount = widget.count ~/ 2;
  late int _downCount = widget.count - widget.count ~/ 2;
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
    bool scrollingUp = _scrollController.position.userScrollDirection ==
        ScrollDirection.forward;
    bool scrollingDown = _scrollController.position.userScrollDirection ==
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
        child: Center(
          child: Spinner(),
        ),
      ),
    );

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification notification) {
        _loadIfNecessary();
        return false; // Return false to allow the notification to continue to be dispatched
      },
      child: CustomScrollView(
        controller: _scrollController,
        physics: BidirectionalListScrollPhysics(
          getScrollAdjustment: _getScrollAdjustment,
        ),
        center: widget.doneStart && widget.header != null
            ? _headerKey
            : _downListKey,
        slivers: [
          if (widget.header != null)
            SliverToBoxAdapter(key: _headerKey, child: widget.header),
          if (widget.count > 0 && !widget.doneStart) spinner,
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
          if (!widget.doneEnd) spinner,
        ],
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
