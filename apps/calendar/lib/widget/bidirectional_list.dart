import 'package:flutter/widgets.dart';
import 'package:very_good_infinite_list/very_good_infinite_list.dart';

typedef BidirectionalFetcher = Future<int> Function(int index, bool reverse);

typedef ItemBuilder = Widget Function(BuildContext context, int index);

class BidirectionalList extends StatefulWidget {
  const BidirectionalList(
      {required this.itemBuilder,
      required this.onFetch,
      this.scrollController,
      super.key});

  final ItemBuilder itemBuilder;
  final BidirectionalFetcher onFetch;
  final ScrollController? scrollController;

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
    return CustomScrollView(
      center: _centerKey,
      controller: widget.scrollController,
      slivers: [
        SliverInfiniteList(
          itemCount: _reverseIndex * -1 - 1,
          isLoading: _reverseLoading,
          onFetchData: () async {
            setState(() {
              _reverseLoading = true;
            });
            try {
              final newIndex = await widget.onFetch(_reverseIndex, true);
              setState(() {
                _reverseIndex = newIndex;
              });
            } finally {
              setState(() {
                _reverseLoading = false;
              });
            }
          },
          itemBuilder: (context, index) {
            return widget.itemBuilder(context, index * -1 - 1);
          },
        ),
        SliverInfiniteList(
          key: _centerKey,
          itemCount: _index,
          isLoading: _loading,
          onFetchData: () async {
            setState(() {
              _loading = true;
            });
            try {
              final newIndex = await widget.onFetch(_index, false);
              assert(
                  newIndex != _index, "onFetch must fetch at least one item");
              setState(() {
                _index = newIndex;
              });
            } finally {
              setState(() {
                _loading = false;
              });
            }
          },
          itemBuilder: (context, index) {
            return widget.itemBuilder(context, index);
          },
        )
      ],
    );
  }
}
