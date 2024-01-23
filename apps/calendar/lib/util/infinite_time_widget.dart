import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

import 'time.dart';

export 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart'
    show PagedChildBuilderDelegate;

class DualList<K, T> {
  const DualList(this.items, this.nextPageKey);
  final List<T> items;
  final K? nextPageKey;
}

class PagedItemsState<T> {
  PagedItemsState(
    this.lists,
  );

  final Map<TimeDirection, DualList<DateTime, T>> lists;
}

class InfiniteTimeWidget<T> extends StatefulWidget {
  const InfiniteTimeWidget(
      {required this.stream,
      required this.onFetch,
      required this.builderDelegate,
      required this.anchor,
      super.key});

  final Stream<PagedItemsState<T>> stream;
  final Future<void> Function(DateTime pageKey, TimeDirection direction)
      onFetch;
  final PagedChildBuilderDelegate<T> builderDelegate;
  final DateTime anchor;

  @override
  InfiniteTimeState createState() => InfiniteTimeState<T>();
}

class InfiniteTimeState<T> extends State<InfiniteTimeWidget<T>> {
  final Key downListKey = UniqueKey();

  late final Map<TimeDirection, PagingController<DateTime, T>>
      _pagingController;
  late StreamSubscription<PagedItemsState<T>> _streamSubscription;

  @override
  void initState() {
    _pagingController = {
      TimeDirection.descending: PagingController(
        firstPageKey: widget.anchor,
        invisibleItemsThreshold: 20,
      )..addPageRequestListener((pageKey) {
          widget.onFetch(pageKey, TimeDirection.descending);
        }),
      TimeDirection.ascending: PagingController(
        firstPageKey: widget.anchor,
        invisibleItemsThreshold: 20,
      )..addPageRequestListener((pageKey) {
          widget.onFetch(pageKey, TimeDirection.ascending);
        }),
    };

    // We could've used StreamBuilder, but that would unnecessarily recreate
    // the entire [PagedSliverGrid] every time the state changes.
    // Instead, handling the subscription ourselves and updating only the
    // _pagingController is more efficient.
    _streamSubscription = widget.stream.listen((pagedItemsState) {
      _pagingController.forEach((direction, controller) {
        controller.value = PagingState(
          itemList: pagedItemsState.lists[direction]!.items,
          nextPageKey: pagedItemsState.lists[direction]!.nextPageKey,
        );
      });
    })
      ..onError((e) {
        _pagingController.forEach((_, controller) {
          controller.error = e;
        });
      });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollable(
      viewportBuilder: (BuildContext context, ViewportOffset position) {
        return Viewport(offset: position, center: downListKey, slivers: [
          PagedSliverList(
            pagingController: _pagingController[TimeDirection.descending]!,
            builderDelegate: widget.builderDelegate,
          ),
          PagedSliverList(
            pagingController: _pagingController[TimeDirection.ascending]!,
            key: downListKey,
            builderDelegate: widget.builderDelegate,
          ),
        ]);
      },
    );
  }

  @override
  void dispose() {
    _pagingController.forEach((_, controller) => controller.dispose());
    _streamSubscription.cancel();
    super.dispose();
  }
}
