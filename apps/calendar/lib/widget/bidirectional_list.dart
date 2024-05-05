import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:very_good_infinite_list/very_good_infinite_list.dart';

typedef BidirectionalFetcher = Future<int> Function(int index, bool reverse);

class BidirectionalList extends StatefulWidget {
  const BidirectionalList(
      {required this.itemBuilder, required this.onFetch, super.key});

  final ItemBuilder itemBuilder;
  final BidirectionalFetcher onFetch;

  @override
  State<BidirectionalList> createState() => BidirectionalListState();
}

class BidirectionalListState extends State<BidirectionalList> {
  int _index = 0;
  bool _loading = false;
  int _reverseIndex = -1;
  bool _reverseLoading = false;

  final Key _centerKey = UniqueKey();

  @override
  Widget build(BuildContext context) {
    return Scrollable(
      viewportBuilder: (BuildContext context, ViewportOffset position) {
        return Viewport(offset: position, center: _centerKey, slivers: [
          InfiniteList(
            itemCount: _reverseIndex * -1 - 1,
            isLoading: _reverseLoading,
            onFetchData: () async {
              _reverseLoading = true;
              try {
                _reverseIndex = await widget.onFetch(_reverseIndex, true);
              } finally {
                _reverseLoading = false;
              }
            },
            reverse: true,
            itemBuilder: (context, index) {
              return widget.itemBuilder(context, index * -1 - 1);
            },
          ),
          InfiniteList(
            key: _centerKey,
            itemCount: _index,
            isLoading: _loading,
            onFetchData: () async {
              _loading = true;
              try {
                _index = await widget.onFetch(_index, true);
              } finally {
                _loading = false;
              }
            },
            itemBuilder: (context, index) {
              return widget.itemBuilder(context, index);
            },
          ),
        ]);
      },
    );
  }
}
