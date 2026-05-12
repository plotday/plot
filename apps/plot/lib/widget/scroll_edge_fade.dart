import 'package:flutter/widgets.dart';

/// Fades the top and bottom edges of a scrollable child to communicate that
/// the region scrolls independently of its surroundings. The top fade is
/// hidden when the child is scrolled to its start; the bottom fade is hidden
/// when scrolled to its end. Both default to visible until the first scroll
/// notification (assume scrollable until proven otherwise).
///
/// The fade is painted as overlay gradients in a [Stack] on top of the child.
/// This requires a known [background] color to fade *to* — without one we'd
/// need a `ShaderMask`/`saveLayer` for true transparency, and that approach
/// produced ~1px paint-time artifacts when child pixels changed underneath
/// (e.g. hover backgrounds in fractional-pixel layouts). When [background]
/// is null, the fade is skipped and the child is returned as-is.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({required this.child, this.background, super.key});

  final Widget child;
  final Color? background;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  static const double _fadeExtent = 16.0;

  bool _atTop = true;
  bool _atBottom = false;

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
    if (atTop != _atTop || atBottom != _atBottom) {
      setState(() {
        _atTop = atTop;
        _atBottom = atBottom;
      });
    }
  }

  bool _onScroll(ScrollNotification n) {
    _updateFromMetrics(n.metrics);
    return false;
  }

  // Fires on initial layout and when the scrollable's metrics change without
  // a user scroll (e.g. content shorter than viewport). Without this, when
  // the child fits in the viewport no [ScrollNotification] ever arrives and
  // the bottom fade — assumed visible by default — would stay forever.
  bool _onMetrics(ScrollMetricsNotification n) {
    _updateFromMetrics(n.metrics);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.background;
    if (bg == null) return widget.child;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onMetrics,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ColoredBox(
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
                  if (!_atTop)
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
        ),
      ),
    );
  }
}
