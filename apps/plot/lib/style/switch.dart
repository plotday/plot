import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';

/// Builds a switch style with better thumb contrast in dark mode.
///
/// Forui's defaults give poor contrast in dark mode: the off-state track is
/// `colors.secondary` (= our `highlight`, 14% alpha) which is barely visible,
/// and the on-state track is `colors.primary` (the accent) which sits at a
/// similar lightness to the white thumb. Both states make it hard to read
/// the thumb's position. Light mode is left untouched.
FSwitchStyleDelta buildSwitchStyleDelta(ColourSchemeData colourScheme) {
  if (colourScheme.brightness != Brightness.dark) {
    return const FSwitchStyleDelta.delta();
  }

  // Solid neutral gray for the off-state track. Lightness sits between the
  // background (~0.26) and the thumb (~0.88) so the thumb reads clearly.
  final offTrackColor =
      RayOklch.fromComponents(0.45, 0.006, 115.0).toColor();

  // Darken the accent for the on-state track so the white thumb stands out.
  // Default accent lightness in dark mode is ~0.78–0.82.
  final onTrackColor = colourScheme.colours.accent
      .withLightness(0.50)
      .toColor();

  return FSwitchStyleDelta.delta(
    trackColor: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.base(offTrackColor),
      FVariantValueDeltaOperation.exact(
        {FSwitchVariantConstraint.selected},
        onTrackColor,
      ),
    ]),
  );
}
