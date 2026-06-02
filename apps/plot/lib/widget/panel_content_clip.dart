import 'package:flutter/widgets.dart';

/// Carries the rounded-corner [borderRadius] that a panel's *page content*
/// should be clipped to, when that content is rendered by a nested navigator
/// whose Overlay lives inside the panel.
///
/// The right-hand thread panel hosts its routes in a nested `AutoRouter`. That
/// router's Navigator creates an Overlay that sits *inside* the panel, so any
/// `FTooltip`/portal raised by a thread page renders into it. If the panel's
/// rounded-corner clip wrapped that router (as the other panels' squircle clip
/// does), it would also clip those tooltips — they extend past the panel edges
/// (notably across the shared seam with the middle panel).
///
/// Instead the right panel paints a rounded *background* and leaves the router
/// unclipped, then advertises the corners here. The page content clips itself
/// to these corners *below* the Navigator — inside [Scaffold] — so the opaque
/// header background still rounds into the corners while tooltips, living in a
/// sibling overlay entry above that clip, escape.
class PanelContentClip extends InheritedWidget {
  const PanelContentClip({
    super.key,
    required this.borderRadius,
    required super.child,
  });

  /// The corners the page content should be clipped to.
  final BorderRadiusGeometry borderRadius;

  /// The clip radius for the enclosing panel, or null when the content is not
  /// inside a corner-clipped panel (e.g. single-panel mobile layouts).
  static BorderRadiusGeometry? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PanelContentClip>()
      ?.borderRadius;

  @override
  bool updateShouldNotify(PanelContentClip oldWidget) =>
      borderRadius != oldWidget.borderRadius;
}
