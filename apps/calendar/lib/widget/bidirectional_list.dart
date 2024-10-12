import 'dart:async';

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

class PositionAdjuster extends ScrollPhysics {
  final double Function() getOffset;

  const PositionAdjuster({
    super.parent,
    required this.getOffset,
  });

  @override
  PositionAdjuster applyTo(ScrollPhysics? ancestor) {
    return PositionAdjuster(
      getOffset: getOffset,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) =>
      super.adjustPositionForNewDimensions(
          oldPosition: oldPosition,
          newPosition: newPosition,
          isScrolling: isScrolling,
          velocity: velocity) +
      getOffset();
}

class BidirectionalList extends StatefulWidget {
  final ItemBuilder builder;
  final ItemFetcher fetcher;
  final int estimatedItemExtent;
  final double overflow; // prefetch at least this multiple of the visible items
  final ScrollController scrollController;

  BidirectionalList({
    required this.builder,
    required this.fetcher,
    ScrollController? scrollController,
    this.estimatedItemExtent = 20,
    this.overflow = 2,
    super.key,
  }) : scrollController = scrollController ?? ScrollController();

  @override
  BidirectionalListState createState() => BidirectionalListState();
}

class BidirectionalListState extends State<BidirectionalList> {
  final Key _centerKey = UniqueKey();
  final GlobalKey _anchorKey = GlobalKey();

  int get _anchorIndex => _count ~/ 2;

  StreamSubscription<void>? _itemSubscription;
  bool _loading = false;
  int _count = 0;
  bool _doneStart = false;
  bool _doneEnd = false;
  double _previousAnchorOffset = 0;

  double getAnchorOffset() {
    final renderObject = _anchorKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return 0;
    final offset = renderObject.localToGlobal(Offset.zero,
        ancestor: context.findRenderObject()!);
    return offset.dy - widget.scrollController.position.pixels;
  }

  int averageItemExtent() {
    if (_count == 0) {
      return widget.estimatedItemExtent;
    }
    return (widget.scrollController.position.maxScrollExtent / _count).floor();
  }

  double averageItemsPerPage() {
    return widget.scrollController.position.viewportDimension /
        averageItemExtent();
  }

  double pagesBefore() {
    return widget.scrollController.position.pixels /
        widget.scrollController.position.viewportDimension;
  }

  double pagesAfter() {
    return (widget.scrollController.position.maxScrollExtent -
            widget.scrollController.position.pixels -
            widget.scrollController.position.viewportDimension) /
        widget.scrollController.position.viewportDimension;
  }

  void _loadInitialItems() {
    _loadMoreItems(
        -((widget.scrollController.position.viewportDimension /
                    widget.estimatedItemExtent) *
                widget.overflow)
            .ceil(),
        ((widget.scrollController.position.viewportDimension /
                    widget.estimatedItemExtent) *
                (widget.overflow + 1))
            .ceil());
  }

  void _loadIfNecessary() {
    if (_loading) return;
    if (_doneStart && _doneEnd) return;
    if (pagesBefore() >= widget.overflow && pagesAfter() >= widget.overflow) {
      return;
    }
    bool scrollingBack = widget.scrollController.position.userScrollDirection ==
        ScrollDirection.reverse;
    bool scrollingForward =
        widget.scrollController.position.userScrollDirection ==
            ScrollDirection.forward;
    final moveBefore =
        -((widget.overflow * (scrollingBack ? 1.5 : 1) - pagesBefore()) *
                averageItemsPerPage())
            .ceil();
    final moveAfter =
        ((widget.overflow * (scrollingForward ? 1.5 : 1) - pagesAfter()) *
                averageItemsPerPage())
            .ceil();
    _previousAnchorOffset = getAnchorOffset();
    _loadMoreItems(moveBefore, moveAfter);
  }

  Future<void> _loadMoreItems(int moveBefore, int moveAfter) async {
    if (_loading) return;
    _itemSubscription?.cancel();
    _loading = true;
    final result = await widget.fetcher(moveBefore, moveAfter);
    setState(() {
      _loading = false;
      _count = result.count;
      _doneStart = result.doneStart;
      _doneEnd = result.doneEnd;
    });
  }

  @override
  void initState() {
    super.initState();
    _loadInitialItems();
    widget.scrollController.addListener(_loadIfNecessary);
  }

  @override
  void dispose() {
    widget.scrollController.dispose();
    _itemSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      center: _centerKey,
      controller: widget.scrollController,
      physics: PositionAdjuster(
        getOffset: () => getAnchorOffset() - _previousAnchorOffset,
      ),
      slivers: [
        if (!_doneStart)
          const SliverToBoxAdapter(
            child: Center(child: Spinner()),
          ),
        SliverList.builder(
          key: _centerKey,
          itemCount: _count,
          itemBuilder: (context, index) {
            final built = widget.builder(context, index);
            if (built != null && index == _anchorIndex) {
              return KeyedSubtree(
                key: _anchorKey,
                child: built,
              );
            } else {
              return built;
            }
          },
        ),
        if (!_doneEnd && _count > 0)
          const SliverToBoxAdapter(
            child: Center(child: Spinner()),
          ),
      ],
    );
  }
}
