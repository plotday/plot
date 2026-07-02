import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Fades the top and bottom edges of a scrollable child to communicate that
/// the region scrolls independently of its surroundings. The top fade is
/// hidden when the child is scrolled to its start; the bottom fade is hidden
/// when scrolled to its end. Both default to *hidden* until the first scroll
/// metric arrives: the most common case is content that fits the viewport
/// (editors, short lists), where the correct answer is no fade at all, and
/// flashing a fade in for one frame on mount is more jarring than flashing
/// it in once when truly-scrollable content has overflowed.
///
/// Two paint modes:
///   * [background] non-null: paint overlay gradients in a [Stack] that fade
///     to the supplied color. Cheaper and crisper, but assumes the child
///     sits on a uniform fill. Produced ~1px paint-time artifacts when used
///     with an alpha-mask shim under hover backgrounds at fractional pixels.
///   * [transparent] true: fade via a [ShaderMask] alpha gradient so the
///     child composites against whatever is behind it. Use when the host
///     surface is non-uniform (e.g. a tinted frame gradient) and a solid
///     [background] would read as a darker card.
///   * Neither set: returns the child as-is. The fade is skipped.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    required this.child,
    this.background,
    this.transparent = false,
    this.top = true,
    super.key,
  }) : assert(
         background == null || !transparent,
         'ScrollEdgeFade: pass either background (overlay fade) or '
         'transparent (alpha-mask fade), not both.',
       );

  final Widget child;
  final Color? background;

  /// Fade the child's alpha at the edges (via [ShaderMask]) rather than
  /// painting an overlay gradient. Use when the child has no opaque
  /// background of its own and must fade into whatever is behind it.
  final bool transparent;

  /// Whether to paint the top edge fade. Set false when something else owns
  /// the top edge — e.g. a pinned sticky header that paints its own fade
  /// below its seam (see [InfiniteList]'s sticky-header overlay). The bottom
  /// fade is unaffected.
  final bool top;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  static const double _fadeExtent = 16.0;

  bool _atTop = true;
  bool _atBottom = true;

  void _updateFromMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return;
    final atMin = metrics.pixels <= metrics.minScrollExtent + 0.5;
    final atMax = metrics.pixels >= metrics.maxScrollExtent - 0.5;
    // For a reversed list (e.g. a chat scrolled to the latest message),
    // axisDirection is up, so the visual top corresponds to the scroll
    // maximum and the visual bottom corresponds to the scroll minimum.
    // Flipping here keeps the bottom fade off when the user is sitting
    // at the latest item — without it, the fade obscures the line that
    // sparked the scroll.
    final reversed = metrics.axisDirection == AxisDirection.up;
    final atTop = reversed ? atMax : atMin;
    final atBottom = reversed ? atMin : atMax;
    if (atTop == _atTop && atBottom == _atBottom) return;
    // ScrollEndNotification fires from inside RenderViewport.performLayout
    // when applyContentDimensions ends a ballistic scroll (e.g. items
    // arriving from an infinite-list fetch). Calling setState during layout
    // trips Flutter's "Build scheduled during frame" assertion; defer to a
    // post-frame callback when invoked from a build/layout/paint phase.
    final phase = SchedulerBinding.instance.schedulerPhase;
    final inFrame = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.postFrameCallbacks;
    if (inFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (atTop == _atTop && atBottom == _atBottom) return;
        setState(() {
          _atTop = atTop;
          _atBottom = atBottom;
        });
      });
    } else {
      setState(() {
        _atTop = atTop;
        _atBottom = atBottom;
      });
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (!_isFromOwnRenderSubtree(n.context)) return false;
    _updateFromMetrics(n.metrics);
    return false;
  }

  // Fires on initial layout and when the scrollable's metrics change without
  // a user scroll (e.g. content shorter than viewport). Without this, when
  // the child fits in the viewport no [ScrollNotification] ever arrives and
  // the bottom fade — assumed visible by default — would stay forever.
  bool _onMetrics(ScrollMetricsNotification n) {
    if (!_isFromOwnRenderSubtree(n.context)) return false;
    _updateFromMetrics(n.metrics);
    return false;
  }

  // Filters out notifications that bubble up via [OverlayPortal] (or any
  // similar logical-but-not-visual descendant). The mention popover, for
  // example, is built into the global [Overlay] but is still an element-tree
  // descendant of the editor — its scrollable list emits metrics that would
  // otherwise corrupt our `_atBottom` state and leave the bottom fade stuck
  // on after the popover closes. Element-tree ancestry can't distinguish
  // those, but render-object ancestry can: overlay children mount their
  // render objects under the [Overlay], not under us.
  bool _isFromOwnRenderSubtree(BuildContext? notificationContext) {
    if (notificationContext == null) return true;
    final myObject = context.findRenderObject();
    final notifObject = notificationContext.findRenderObject();
    if (myObject == null || notifObject == null) return true;
    RenderObject? cursor = notifObject;
    while (cursor != null) {
      if (identical(cursor, myObject)) return true;
      cursor = cursor.parent;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.background;
    if (bg == null && !widget.transparent) return widget.child;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onMetrics,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: bg != null ? _overlay(bg) : _alphaMask(),
      ),
    );
  }

  Widget _overlay(Color bg) {
    return ColoredBox(
      color: bg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Skip the fade for short panels — it would consume most of the
          // visible content.
          if (constraints.maxHeight <= _fadeExtent * 3) return widget.child;
          final transparent = bg.withValues(alpha: 0);
          return Stack(
            children: [
              widget.child,
              if (!_atTop && widget.top)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: _fadeExtent,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [bg, transparent],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!_atBottom)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: _fadeExtent,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [transparent, bg],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _alphaMask() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxH = constraints.maxHeight;
        // Treat the top edge as "already resolved" when the caller has
        // disabled the top fade, so a list that only needs the top fade
        // short-circuits to the plain child.
        final topActive = !_atTop && widget.top;
        if (maxH <= _fadeExtent * 3 || (!topActive && _atBottom)) {
          return widget.child;
        }
        // RGB is ignored by [BlendMode.dstIn]; only alpha matters. Opaque
        // stops keep the child fully visible; transparent stops at the
        // active edges erase it gradually.
        const opaque = Color(0xFF000000);
        const clear = Color(0x00000000);
        final fade = (_fadeExtent / maxH).clamp(0.0, 0.5);
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              topActive ? clear : opaque,
              opaque,
              opaque,
              _atBottom ? opaque : clear,
            ],
            stops: [0.0, fade, 1.0 - fade, 1.0],
          ).createShader(rect),
          child: widget.child,
        );
      },
    );
  }
}
