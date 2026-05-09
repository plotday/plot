import 'package:flutter/widgets.dart';

/// Wraps a tappable area with mouse-cursor + hover state tracking, so each
/// onboarding button can render a hover variant via a builder. Mirrors the
/// pattern used by the theme buttons in `widget/list_tile.dart`, adapted for
/// the colored backdrops onboarding paints over (where the destination color
/// depends on whether the surface is opaque-white or translucent-on-color).
class OnboardingHoverable extends StatefulWidget {
  const OnboardingHoverable({
    required this.builder,
    required this.onTap,
    this.behavior = HitTestBehavior.opaque,
    super.key,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback onTap;
  final HitTestBehavior behavior;

  @override
  State<OnboardingHoverable> createState() => _OnboardingHoverableState();
}

class _OnboardingHoverableState extends State<OnboardingHoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: widget.behavior,
        child: widget.builder(context, _hovered),
      ),
    );
  }
}
