import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';

typedef ThreadCenterBuilder = Widget Function(ThreadId threadId);
typedef ThreadPreviewBuilder = Widget Function(Thread thread);

/// A Gmail-style horizontal carousel for navigating between threads by swipe.
///
/// Pages horizontally over the feed's threads ([threads]). The thread the user
/// has settled on is rendered as the full live thread view ([centerBuilder]);
/// every other page is a cheap read-only preview ([previewBuilder]). Only one
/// live thread is ever mounted, so neighbors never mark read or claim focus.
///
/// The [PageView] owns the slide and its own page index, so the finger-following
/// drag always completes — there is no re-centering jump. When a swipe settles
/// on a new page, [onThreadChanged] fires (the host wires it to
/// `PriorityBloc.setThread`). No routes are pushed, so Back returns to the list
/// and the back stack never grows.
///
/// When the live thread is not in [threads] (a deep link or a search-filtered
/// thread, [initialIndex] < 0) or the feed is empty, the carousel renders a
/// single inert page for [centerThreadId] — today's behavior, no swipe.
class ThreadCarousel extends StatefulWidget {
  const ThreadCarousel({
    required this.centerThreadId,
    required this.threads,
    required this.initialIndex,
    required this.centerBuilder,
    required this.previewBuilder,
    required this.onThreadChanged,
    this.reserveLeftEdgeBackZone = false,
    this.edgeZoneWidth = 20,
    super.key,
  });

  /// The id of the thread that is currently live. Always valid, even when it is
  /// not in [threads] (deep link / search-filtered).
  final ThreadId centerThreadId;

  /// The ordered feed thread items the user can swipe through. May be empty
  /// (no list context yet) or omit [centerThreadId] (deep link).
  final List<Thread> threads;

  /// Index of [centerThreadId] within [threads], or -1 when it is not present.
  final int initialIndex;

  final ThreadCenterBuilder centerBuilder;
  final ThreadPreviewBuilder previewBuilder;

  /// Called when a swipe settles on a different thread. The host promotes it
  /// (e.g. `PriorityBloc.setThread(thread)`).
  final void Function(Thread thread) onThreadChanged;

  /// On iOS, reserve a strip at the very left edge for the system
  /// edge-swipe-back gesture instead of the carousel.
  final bool reserveLeftEdgeBackZone;
  final double edgeZoneWidth;

  @override
  State<ThreadCarousel> createState() => _ThreadCarouselState();
}

class _ThreadCarouselState extends State<ThreadCarousel> {
  late PageController _controller;

  /// Per-carousel note-scroll offsets keyed by thread id, so swiping away from
  /// a thread and back restores where the user was reading. Cleared when the
  /// carousel is disposed (the user leaves the thread view).
  final Map<String, double> _scrollOffsets = {};

  /// True while the active pointer started inside the reserved left-edge zone;
  /// the PageView is frozen so the route's back gesture can win.
  bool _edgeBlocked = false;

  /// Index of the live (settled) thread within [widget.threads] in multi mode.
  late int _liveIndex;

  bool get _multi => widget.threads.isNotEmpty && widget.initialIndex >= 0;

  @override
  void initState() {
    super.initState();
    _liveIndex = _multi ? widget.initialIndex : 0;
    _controller = PageController(initialPage: _liveIndex);
  }

  @override
  void didUpdateWidget(ThreadCarousel old) {
    super.didUpdateWidget(old);
    // Keep the controller anchored to the live thread when the feed changes
    // out from under us (reorder, or the feed loading after a deep link). This
    // never fires during a user swipe: the swipe keeps [_liveIndex] in sync
    // with the settled page via [_onScrollEnd] before the rebuild arrives.
    if (!_multi) {
      if (_liveIndex != 0) {
        _liveIndex = 0;
        _anchorTo(0);
      }
      return;
    }
    final desired =
        widget.threads.indexWhere((t) => t.id == widget.centerThreadId);
    if (desired >= 0 && desired != _liveIndex) {
      _liveIndex = desired;
      _anchorTo(desired);
    }
  }

  /// Jump the controller to [page] without animation, after the new children
  /// lay out. Guards against redundant jumps so it cannot interrupt a settle.
  void _anchorTo(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _controller.hasClients &&
          _controller.page?.round() != page) {
        _controller.jumpToPage(page);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Promote the page the user settled on. Runs only when the horizontal
  /// PageView itself comes to rest — note-list (vertical) scroll-ends are
  /// ignored, and a drag that springs back to the same page is a no-op.
  bool _onScrollEnd(ScrollEndNotification notification) {
    if (notification.metrics.axis != Axis.horizontal) return false;
    if (!_multi || !_controller.hasClients) return false;
    final page = _controller.page?.round();
    if (page == null || page == _liveIndex) return false;
    if (page < 0 || page >= widget.threads.length) return false;
    setState(() => _liveIndex = page);
    widget.onThreadChanged(widget.threads[page]);
    return false;
  }

  Widget _buildPage(BuildContext context, int index) {
    if (!_multi || index == _liveIndex) {
      final id = _multi ? widget.threads[index].id : widget.centerThreadId;
      return KeyedSubtree(
        key: ValueKey(id),
        child: widget.centerBuilder(id),
      );
    }
    return widget.previewBuilder(widget.threads[index]);
  }

  @override
  Widget build(BuildContext context) {
    final pageView = PageView.builder(
      controller: _controller,
      physics: _edgeBlocked
          ? const NeverScrollableScrollPhysics()
          : null, // default PageScrollPhysics (platform-appropriate)
      itemCount: _multi ? widget.threads.length : 1,
      itemBuilder: _buildPage,
    );

    final body = NotificationListener<ScrollEndNotification>(
      onNotification: _onScrollEnd,
      child: CarouselScrollCache(offsets: _scrollOffsets, child: pageView),
    );

    if (!widget.reserveLeftEdgeBackZone) return body;

    // Freeze the PageView for any gesture that begins in the left-edge strip
    // so the route's edge-swipe-back recognizer wins the arena there.
    return Listener(
      onPointerDown: (event) {
        final blocked = event.localPosition.dx <= widget.edgeZoneWidth;
        if (blocked != _edgeBlocked) setState(() => _edgeBlocked = blocked);
      },
      onPointerUp: (_) {
        if (_edgeBlocked) setState(() => _edgeBlocked = false);
      },
      onPointerCancel: (_) {
        if (_edgeBlocked) setState(() => _edgeBlocked = false);
      },
      child: body,
    );
  }
}

/// Carries the carousel's per-thread note-scroll offsets down to the live
/// thread page, which saves its offset on dispose and restores it on re-entry
/// so swiping away and back preserves the reading position.
///
/// Absent off-carousel (desktop/web, or the inert single-thread case is still
/// under one), so the thread page's normal scroll-to-unread behavior is
/// unchanged anywhere this is not present.
class CarouselScrollCache extends InheritedWidget {
  const CarouselScrollCache({
    required this.offsets,
    required super.child,
    super.key,
  });

  final Map<String, double> offsets;

  double? offsetFor(ThreadId id) => offsets[id.toString()];

  void save(ThreadId id, double offset) => offsets[id.toString()] = offset;

  static CarouselScrollCache? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CarouselScrollCache>();

  @override
  bool updateShouldNotify(CarouselScrollCache oldWidget) => false;
}
