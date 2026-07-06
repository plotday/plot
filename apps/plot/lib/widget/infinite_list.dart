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

  /// Whether one of this list's items currently holds primary keyboard focus.
  /// Unlike [focusedIndex], this is false when focus has moved elsewhere
  /// (e.g. into a note editor) even if a list item's FocusNode reports
  /// [FocusNode.hasFocus] via a descendant.
  bool get hasPrimaryFocus {
    for (final node in _focusNodes.values) {
      if (node.hasPrimaryFocus) return true;
    }
    return false;
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
          }
          notifyListeners();
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

  /// Whether [jumpToTop] has been requested since the last acknowledgement.
  bool _jumpToTopRequested = false;
  bool get jumpToTopRequested => _jumpToTopRequested;

  /// Request the associated [InfiniteList] to scroll to the top.
  void jumpToTop() {
    _jumpToTopRequested = true;
    notifyListeners();
  }

  /// Acknowledge a pending [jumpToTop] request.
  void acknowledgeJumpToTop() {
    _jumpToTopRequested = false;
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

  /// Returns a stable identity key for the item at [index].
  /// When provided, enables key-based element reuse across index shifts
  /// (via `findChildIndexCallback`) and — unless [anchorCorrection] is
  /// false — anchor-based scroll correction: if items are added/removed
  /// above the viewport, the scroll offset is adjusted so the first
  /// visible item stays in place.
  final String Function(int index)? itemKey;

  /// Whether [itemKey] also drives the scroll-offset anchor correction.
  /// Disable when the caller's item heights vary a lot or items are
  /// inserted/removed at zero height (e.g. the activity feed's collapsing
  /// move ghosts) — the correction estimates by AVERAGE item extent, so it
  /// would over-correct those cases. Key-based element reuse stays on.
  final bool anchorCorrection;

  /// Custom cache extent for the underlying [CustomScrollView].
  /// Set to [double.infinity] to keep all items alive and prevent
  /// disposal/recreation when scrolling (useful for short lists with
  /// expensive-to-recreate items like images).
  final double? cacheExtent;

  /// Initial scroll offset when creating an internal ScrollController.
  /// Ignored when [scrollController] is provided externally.
  final double initialScrollOffset;

  /// Widget shown in place of the trailing fetch-spinner when the list is
  /// empty (`count == 0`). Without this, an empty list with `!doneEnd`
  /// fills the viewport with a centered spinner — fine while data is
  /// loading, but misleading when the caller already knows the result
  /// set is genuinely empty. Pass an empty-state widget here once the
  /// caller's own "loaded" gate has fired.
  final Widget? emptyPlaceholder;

  /// Called when the scroll offset changes, allowing callers to persist it.
  final ValueChanged<double>? onScrollOffsetChanged;

  /// How dragging the scroll view should dismiss the on-screen keyboard.
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Sticky headers (overlay approach).
  ///
  /// Returns true for item indices that act as "section headers" — the
  /// items whose label should pin to the top of the viewport while their
  /// section's content scrolls beneath. The list attaches a measurement
  /// key to each such item so it can track their live positions without
  /// restructuring the (single, flat) sliver.
  final bool Function(int index)? isStickyHeader;

  /// Builds the pinned overlay for the given header [index] — typically the
  /// same header widget the list renders inline. When both this and
  /// [isStickyHeader] are non-null, the list overlays a single pinned header
  /// on top of the scroll view (and slides it up as the next header reaches
  /// the top). Null disables the overlay entirely, so existing callers are
  /// unaffected.
  final Widget Function(BuildContext context, int index)? stickyHeaderBuilder;

  InfiniteList({
    required this.builder,
    required this.count,
    this.fetcher,
    bool? doneEnd,
    this.scrollController,
    this.scrollStorageKey,
    this.estimatedItemExtent = 75,
    // One page of buffer past the viewport is enough — the fetcher fires
    // again as the user scrolls into it. Larger values (the previous
    // default was 3) ask for `pageSize * (overflow * 2 + 1)` items per
    // round, which over-fetches on tall windows: e.g. pageSize=28 +
    // overflow=3 asks for 196 items, well past what a typical agenda or
    // feed can supply, causing the fetcher's "still under target" branch
    // to fire repeatedly before content catches up.
    this.overflow = 1,
    this.reverse = false,
    this.onReorder,
    this.nonReorderablePrefixCount = 0,
    this.separatorBuilder,
    this.itemKey,
    this.anchorCorrection = true,
    this.cacheExtent,
    this.initialScrollOffset = 0.0,
    this.onScrollOffsetChanged,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.manual,
    this.emptyPlaceholder,
    this.isStickyHeader,
    this.stickyHeaderBuilder,
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

  // ── Sticky-header overlay state ─────────────────────────────────────
  /// Height of the scroll-edge fade painted below a pinned sticky header.
  /// Matches [ScrollEdgeFade]'s extent so the two read as one system.
  static const double _stickyFadeExtent = 16.0;

  /// Measurement keys for currently-tracked header items, keyed by the
  /// item's stable [InfiniteList.itemKey] string so a key follows its
  /// logical item across index shifts. Only header items get one.
  final Map<String, GlobalKey> _headerKeys = {};

  /// Wraps the whole `Stack`, giving the overlay a stable origin (the
  /// viewport's top edge in global coordinates) to measure against.
  final GlobalKey _stackKey = GlobalKey();

  /// Wraps the rendered overlay so its height can be measured for the
  /// push-up hand-off to the next header.
  final GlobalKey _overlayKey = GlobalKey();

  /// Index of the header currently pinned at the top (null = none).
  int? _activeStickyIndex;

  /// Vertical translation of the pinned header. 0 while resting at the
  /// top; negative while the next header pushes it up and out.
  double _stickyPush = 0;

  /// Whether the pinned header is "floating" — the real in-list header it
  /// mirrors has scrolled up under the top edge (or off past the cache
  /// extent). Only while floating does the overlay paint its own bottom
  /// divider: at rest the overlay coincides with the real header, so we
  /// let the real, dynamically-coloured shared divider below the first
  /// row show through instead of occluding it with a neutral line.
  bool _stickyFloating = false;

  /// Returns the measurement key for [stableKey], creating it on first use.
  GlobalKey _headerKey(String stableKey) =>
      _headerKeys.putIfAbsent(stableKey, () => GlobalKey());

  bool get _stickyEnabled =>
      widget.stickyHeaderBuilder != null && widget.isStickyHeader != null;

  /// Recomputes which header is pinned and how far it is pushed up, from
  /// the live positions of the tracked header items. Cheap: only headers
  /// currently laid out (visible + cache extent) have a render box, and
  /// there are only a handful on screen at once. Called on every scroll
  /// update and after layout-changing rebuilds.
  void _updateStickyHeader() {
    if (!_stickyEnabled) return;
    final stackContext = _stackKey.currentContext;
    if (stackContext == null) return;
    final stackBox = stackContext.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    final viewportTop = stackBox.localToGlobal(Offset.zero).dy;

    // Collect (index, topRelativeToViewport) for every tracked header
    // that is currently laid out. `_headerKeys` is keyed by stable string;
    // resolve each back to its current index via widget.itemKey.
    int? activeIndex;
    double activeTop = double.negativeInfinity;
    double? nextTop; // top of the first header strictly below the pin line.

    for (var i = 0; i < widget.count; i++) {
      if (!(widget.isStickyHeader?.call(i) ?? false)) continue;
      final stableKey = widget.itemKey?.call(i) ?? 'idx_$i';
      final key = _headerKeys[stableKey];
      final ctx = key?.currentContext;
      if (ctx == null) continue; // scrolled out of the cache extent
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy - viewportTop;
      // A header at or above the pin line (top <= ~0) is a pin candidate;
      // the lowest such one wins (the section we're currently inside).
      if (top <= 0.5) {
        if (top > activeTop) {
          activeTop = top;
          activeIndex = i;
        }
      } else if (nextTop == null || top < nextTop) {
        nextTop = top;
      }
    }

    // If no tracked header is at/above the pin line, the active section's
    // header has scrolled past the cache extent — keep the last known one
    // pinned (that's the whole point of the overlay).
    var newIndex = activeIndex ?? _activeStickyIndex;

    // At (or above) the top of the list — resting or overscroll-bouncing —
    // nothing should be pinned: the real first header is fully visible.
    // Without this, overscroll drags the real header down while the overlay
    // stays glued to the top, showing two copies.
    final pos = _scrollController.hasClients ? _scrollController.position : null;
    final atTop = pos == null || pos.pixels <= 0.5;

    // "Floating" — the overlay is shown only when the real header it mirrors
    // has scrolled up under the top edge. At rest / overscroll (atTop) the
    // real header shows instead; when the header is measurable, it must have
    // reached the top edge; when it has scrolled past the cache extent
    // (unmeasurable) it is necessarily above.
    //
    // Threshold is the pin line itself (`< 0.5`), NOT `< -0.5`. This handler
    // runs from the ScrollUpdateNotification, where `pos.pixels` already holds
    // the new offset but the header render-boxes still reflect the PREVIOUS
    // layout — so on the very first scroll frame `activeTop` still measures
    // ~0. A `-0.5` gate leaves `floating` false for that one frame, so the
    // real header renders a pixel up (uncovered) and the overlay snaps it back
    // down the next frame — a visible 1px jump. Flipping at the pin line makes
    // the overlay cover the header the same frame it starts to scroll away.
    // `activeIndex` candidates already satisfy `top <= 0.5`, so this only ever
    // aligns the overlay a sub-pixel earlier at rest — invisible — while
    // killing the transition jump.
    final bool floating;
    if (atTop) {
      floating = false;
    } else if (activeIndex != null) {
      floating = activeTop < 0.5;
    } else {
      floating = newIndex != null;
    }

    // Push-up hand-off: when the next header rises into the overlay's band,
    // slide the pinned header up by the overlap so the two swap cleanly.
    var newPush = 0.0;
    if (floating && newIndex != null && nextTop != null) {
      final overlayHeight = _overlayHeight();
      if (nextTop < overlayHeight) {
        newPush = nextTop - overlayHeight; // negative → slides up
      }
    }

    if (newIndex != _activeStickyIndex ||
        floating != _stickyFloating ||
        (newPush - _stickyPush).abs() > 0.5) {
      setState(() {
        _activeStickyIndex = newIndex;
        _stickyFloating = floating;
        _stickyPush = newPush;
      });
    }
  }

  /// Measured height of the current overlay, falling back to a nominal
  /// value before the first layout.
  double _overlayHeight() {
    final box = _overlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.height > 0) {
      return box.size.height;
    }
    return 40;
  }
  // ────────────────────────────────────────────────────────────────────

  /// `widget.count` and `lastVisible` at the most recent fetcher call.
  /// Used by [_loadIfNecessary] to suppress redundant fetches: if neither
  /// the count nor the visible window has advanced since we last asked,
  /// the fetcher already had its shot and couldn't grow the list past
  /// here — wait for the user to scroll closer to the bottom before
  /// trying again. Without this, sparse data sources (e.g. a fresh
  /// agenda where the fetcher can only surface ~30 fill-days per round
  /// while [InfiniteList]'s overflow buffer asks for several pages on a
  /// tall window) loop on every `didUpdateWidget`.
  int _lastFetchCount = -1;
  int _lastFetchLastVisible = -1;

  /// Snapshot of (index -> key) for visible items, used for anchor correction.
  Map<int, String> _visibleKeySnapshot = {};
  int _lastSnapshotCount = 0;

  /// Largest per-item extent observed from scroll metrics. Flutter does not
  /// always re-run the sliver's `performLayout` when only `childCount` changes,
  /// which leaves `maxScrollExtent` stale. Using `extentTotal / totalItems`
  /// directly then shrinks as `totalItems` grows, inflating the computed
  /// visible range and causing a runaway fetch loop. Tracking the max
  /// observed average floors the estimate at its most trustworthy value.
  double _maxObservedItemExtent = 0;

  (int, int) estimateVisibleIndexes() {
    if (!_scrollController.hasClients ||
        _scrollController.position.viewportDimension <= 0) {
      return (0, 0);
    }
    final totalItems = widget.count;
    if (totalItems == 0) return (0, 0);
    final rawItemExtent =
        _scrollController.position.extentTotal / totalItems;
    if (rawItemExtent > _maxObservedItemExtent) {
      _maxObservedItemExtent = rawItemExtent;
    }
    final averageItemExtent = _maxObservedItemExtent > 0
        ? _maxObservedItemExtent
        : widget.estimatedItemExtent.toDouble();
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
    if (_fetching) return;
    if (!_scrollController.hasClients) return;

    final (firstVisibleEst, lastVisibleEst) = estimateVisibleIndexes();
    // The estimator divides total scroll extent by item count to derive
    // an average item height. When the list first renders with very few
    // items but a large fill-remaining sliver, that average snaps to a
    // huge value (cached in `_maxObservedItemExtent`) and never shrinks,
    // making the at-bottom view incorrectly look like "lots more below".
    // Detect the true at-bottom state via maxScrollExtent so the fetcher
    // fires reliably even when the estimator is stale.
    final pos = _scrollController.position;
    final atEnd = pos.maxScrollExtent <= 0
        ? false
        : pos.pixels >= pos.maxScrollExtent - 1.0;
    final firstVisible = firstVisibleEst;
    final lastVisible =
        atEnd ? widget.count - 1 : lastVisibleEst;
    final pageSize = lastVisible - firstVisible + 1;

    // Check if we have enough buffer at the end
    final pagesAfter = (widget.count - 1 - lastVisible) / pageSize;

    if (widget.doneEnd || (!atEnd && pagesAfter >= widget.overflow)) {
      return;
    }

    // Back-off when the fetcher saturated. If neither the underlying
    // count nor the visible window has advanced since we last asked,
    // re-firing now would just hand the fetcher the same (or smaller)
    // window — and rebuild-driven re-entries (sync emissions, parent
    // re-renders) would do this hundreds of times in a single frame
    // budget. The scroll listener clears these on real movement so the
    // next page is still fetched ahead of the user.
    //
    // When the user is truly at the bottom (`atEnd`), bypass back-off:
    // a previous fetch may have already updated lastFetchCount to the
    // current count, but the user genuinely needs more rows surfaced.
    if (!atEnd &&
        widget.count <= _lastFetchCount &&
        lastVisible <= _lastFetchLastVisible) {
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

    _lastFetchCount = widget.count;
    _lastFetchLastVisible = lastVisible;

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
    _scrollController = widget.scrollController ??
        ScrollController(initialScrollOffset: widget.initialScrollOffset);
    if (widget.onScrollOffsetChanged != null) {
      _scrollController.addListener(_onScrollChanged);
    }
    widget.controller.addListener(_onControllerChanged);

    // Call _loadIfNecessary on the first frame after initial render
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.clamp(0, widget.count - 1);
      _loadIfNecessary();
      _updateKeySnapshot();
      _updateStickyHeader();
    });
  }

  void _onScrollChanged() {
    if (_scrollController.hasClients) {
      widget.onScrollOffsetChanged?.call(_scrollController.offset);
    }
  }

  void _onControllerChanged() {
    if (widget.controller.jumpToTopRequested) {
      widget.controller.acknowledgeJumpToTop();
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScrollChanged);
    widget.controller.removeListener(_onControllerChanged);
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant InfiniteList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (widget.onReorder != null && oldWidget.count != widget.count) {
      log.info(
        '[InfiniteList.didUpdateWidget] count=${oldWidget.count}->${widget.count}',
      );
    }

    // Anchor-based scroll correction: if items changed and we have a key
    // function, find the first visible item in the new list and adjust offset.
    if (widget.itemKey != null &&
        widget.anchorCorrection &&
        oldWidget.count != widget.count &&
        _scrollController.hasClients &&
        _scrollController.offset > 0 &&
        _visibleKeySnapshot.isNotEmpty) {
      _correctScrollForAnchor();
    }

    if (oldWidget.count == widget.count &&
        oldWidget.doneEnd == widget.doneEnd) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.clamp(0, widget.count - 1);
      _loadIfNecessary();
      _updateKeySnapshot();
      _updateStickyHeader();
    });
  }

  /// Adjusts scroll offset so the first visible item stays in place after
  /// items are added/removed above.
  void _correctScrollForAnchor() {
    // Find anchor: try each visible item from the snapshot
    final sortedEntries = _visibleKeySnapshot.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final entry in sortedEntries) {
      final oldIndex = entry.key;
      final anchorKey = entry.value;

      // Search for this key in the new item list
      int? newIndex;
      for (var i = 0; i < widget.count; i++) {
        if (widget.itemKey!(i) == anchorKey) {
          newIndex = i;
          break;
        }
      }

      if (newIndex != null && newIndex != oldIndex) {
        final indexDelta = newIndex - oldIndex;
        // Use offset/firstVisibleIndex for the average: this excludes
        // non-item slivers (e.g. the loading spinner) that inflate extentTotal.
        final averageItemExtent = oldIndex > 0
            ? _scrollController.offset / oldIndex
            : _scrollController.position.extentTotal / _lastSnapshotCount;
        final correction = indexDelta * averageItemExtent;
        final newOffset = (_scrollController.offset + correction)
            .clamp(0.0, _scrollController.position.maxScrollExtent + correction);
        log.info(
          '[InfiniteList] anchor correction: key=$anchorKey '
          'oldIndex=$oldIndex newIndex=$newIndex delta=$indexDelta '
          'correction=$correction',
        );
        _scrollController.jumpTo(newOffset);
        break;
      }
    }
  }

  /// Updates the visible key snapshot for anchor correction.
  void _updateKeySnapshot() {
    if (widget.itemKey == null || !_scrollController.hasClients) return;
    final (first, last) = estimateVisibleIndexes();
    final snapshot = <int, String>{};
    for (var i = first; i <= last && i < widget.count; i++) {
      snapshot[i] = widget.itemKey!(i);
    }
    _visibleKeySnapshot = snapshot;
    _lastSnapshotCount = widget.count;
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
          key: child.key ?? ValueKey('item_$index'),
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

  Widget _buildItem(BuildContext context, int reorderIndex) {
    final offset = _prefixCount;
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

    // Tag header items with a measurement key so the sticky overlay can read
    // their live positions. Keyed by the stable itemKey string so the
    // GlobalKey follows its logical item across index shifts.
    if (_stickyEnabled && (widget.isStickyHeader?.call(index) ?? false)) {
      final stableKey = widget.itemKey?.call(index) ?? 'idx_$index';
      child = KeyedSubtree(key: _headerKey(stableKey), child: child);
    }

    // Use itemKey for stable identity when available, falling back to
    // child key, then index-based key.
    final itemKeyValue = widget.itemKey?.call(index);
    final wrapperKey = itemKeyValue != null
        ? ValueKey(itemKeyValue)
        : child.key ?? ValueKey('item_$index');

    return MouseRegion(
      key: wrapperKey,
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
  }

  Widget _buildSliverList() {
    final offset = _prefixCount;
    final count = widget.count - offset;

    // When reordering is not needed, use a plain SliverList. When itemKey is
    // also provided, findChildIndexCallback enables key-based element reuse
    // so widget state (e.g. loaded images) isn't lost when items shift.
    if (widget.onReorder == null) {
      return SliverList(
        key: _listKey,
        delegate: SliverChildBuilderDelegate(
          _buildItem,
          childCount: count,
          findChildIndexCallback: widget.itemKey == null
              ? null
              : (Key key) {
                  if (key is ValueKey<String>) {
                    for (var i = 0; i < count; i++) {
                      if (widget.itemKey!(i + offset) == key.value) {
                        return i;
                      }
                    }
                  }
                  return null;
                },
        ),
      );
    }

    return SliverReorderableList(
      key: _listKey,
      itemCount: count,
      itemBuilder: _buildItem,
      // Mirror the SliverList path's key-based child reuse so reorders
      // migrate State (BlockDropZones, focused fields, animations,
      // image caches) instead of disposing + recreating each moved
      // child. Without this, Flutter can only match children by index,
      // and every reorder runs a mount-before-unmount race that
      // wipes State even though the keys are stable.
      findChildIndexCallback: widget.itemKey == null
          ? null
          : (Key key) {
              if (key is ValueKey<String>) {
                for (var i = 0; i < count; i++) {
                  if (widget.itemKey!(i + offset) == key.value) {
                    return i;
                  }
                }
              }
              return null;
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
      onReorderItem: (oldReorderIndex, newReorderIndex) {
        log.info(
          '[InfiniteList.onReorder] old=$oldReorderIndex new=$newReorderIndex '
          'count=$count offset=$offset',
        );
        final onReorder = widget.onReorder?.call(oldReorderIndex + offset);
        onReorder?.call(newReorderIndex + offset);
        log.info('[InfiniteList.onReorder] parent callback returned');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Recompute the pinned header against the freshly-laid-out list after
    // every build, not just on scroll — so it can't go stale when the list
    // rebuilds without a scroll (data changes, viewport resize, hot reload).
    // _updateStickyHeader only setStates on a real change, so this converges.
    if (_stickyEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateStickyHeader();
      });
    }

    const spinner = SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0),
        child: Center(child: Spinner()),
      ),
    );

    final scrollView = NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (notification is ScrollUpdateNotification) {
          _loadIfNecessary();
          _updateKeySnapshot();
          _updateStickyHeader();
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
            scrollCacheExtent: widget.cacheExtent != null
                ? ScrollCacheExtent.pixels(widget.cacheExtent!)
                : null,
            keyboardDismissBehavior: widget.keyboardDismissBehavior,
            slivers: [
              if (_prefixCount > 0) _buildFixedPrefix(),
              _buildSliverList(),
              if (widget.separatorBuilder != null && widget.count > 0)
                SliverToBoxAdapter(
                  child: widget.separatorBuilder!(context, widget.count),
                ),
              if (widget.count == 0 && widget.emptyPlaceholder != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: widget.emptyPlaceholder!,
                )
              else if (!widget.doneEnd)
                widget.count == 0
                    ? const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: Spinner()),
                      )
                    : spinner,
            ],
          ),
        ),
      ),
    );

    if (!_stickyEnabled) return scrollView;

    // Layer one pinned header over the scroll view. The header widget is the
    // same one the list renders inline (via stickyHeaderBuilder), so at rest
    // it sits exactly over the real header. [_stickyPush] slides it up as the
    // next header arrives; the
    // Stack clips the overshoot. The overlay is NOT wrapped in IgnorePointer
    // so interactive headers (e.g. the feed's "Do all later" button) still
    // work; empty header areas don't block hit tests, so scroll gestures on
    // them still reach the list beneath.
    // Only render the overlay while floating — at rest / overscroll the real
    // in-list header is visible, so a pinned copy would just duplicate it.
    final activeIndex = _activeStickyIndex;
    // [_activeStickyIndex] is a "keep last known" index (see _updateStickyHeader:
    // `activeIndex ?? _activeStickyIndex`), so it can outlive the layout it was
    // captured in. If the item list reshuffles before the next scroll update —
    // a thread moves, a ghost splices in/out, a section collapses — that stale
    // index may now point at a non-header row, and stickyHeaderBuilder would
    // cast it to a header type and throw. Re-verify it still points at a sticky
    // header before building the overlay; if not, drop the overlay this frame
    // and let the next _updateStickyHeader recompute.
    final overlay = (_stickyFloating &&
            activeIndex != null &&
            activeIndex >= 0 &&
            activeIndex < widget.count &&
            (widget.isStickyHeader?.call(activeIndex) ?? false))
        ? widget.stickyHeaderBuilder!(context, activeIndex)
        : null;

    final bg = context.theme.colors.background;
    return Stack(
      key: _stackKey,
      clipBehavior: Clip.hardEdge,
      children: [
        scrollView,
        if (overlay != null)
          Positioned(
            top: _stickyPush,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Measured subtree: header + seam ONLY. The push-up hand-off
                // reads this height via [_overlayKey], so the edge fade below
                // must stay outside it or the next header would start sliding
                // up a fade-extent too early.
                KeyedSubtree(
                  key: _overlayKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Opaque base so scrolling content never bleeds through a
                      // header with a translucent band.
                      ColoredBox(color: bg, child: overlay),
                      // Seam divider as an explicit 1px child — NOT a
                      // BoxDecoration border, which paints behind the child and
                      // would be occluded by the header's own opaque band.
                      // While floating, the list's real header↔item divider is
                      // owned by the scrolled-away next item, so the overlay
                      // supplies its own. Matches the list's divider colour.
                      Container(
                        height: 1,
                        color: Color.alphaBlend(
                          context.theme.colors.border,
                          bg,
                        ),
                      ),
                    ],
                  ),
                ),
                // Scroll-edge fade rendered BELOW the pinned header's seam, so
                // rows dissolve into the header band as they scroll under it —
                // rather than the fade sitting on top of (and washing out) the
                // header itself. Only present while floating (content is
                // scrolled), IgnorePointer so the rows beneath stay tappable,
                // and outside [_overlayKey] so it doesn't inflate the hand-off
                // height. The host list's own top fade is disabled in this
                // mode (see [ScrollEdgeFade.top]).
                IgnorePointer(
                  child: SizedBox(
                    height: _stickyFadeExtent,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [bg, bg.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
