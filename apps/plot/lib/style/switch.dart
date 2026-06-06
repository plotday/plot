import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/style/colors.dart';

/// IMPORTANT — sizing convention for `FSwitch`:
///
/// A bare `FSwitch` renders LARGE (its default forui size). Every switch in
/// the app must be shrunk to the standard 32×20 footprint by wrapping it:
///
/// ```dart
/// SizedBox(
///   width: 32,
///   height: 20,
///   child: FittedBox(fit: BoxFit.contain, child: FSwitch(...)),
/// )
/// ```
///
/// See `lib/widget/setup_source.dart`, `lib/widget/form.dart`, and
/// `lib/command/twist.dart` for existing call sites. Dropping in a raw
/// `FSwitch` produces oversized green toggles that don't match the rest of
/// the UI — always use the wrapper.
///
/// Builds a switch style with better thumb contrast against the track.
///
/// Forui's defaults render the thumb and the off-state track at very similar
/// lightnesses in both modes: in light mode the white thumb sits on a 94%-
/// lightness highlight; in dark mode the white thumb sits on a 14%-alpha
/// highlight that nearly disappears against the dark background. The
/// on-state accent in dark mode is also too close to the white thumb. We
/// pick solid track colors with enough lightness gap to read the thumb's
/// position clearly.
FSwitchStyleDelta buildSwitchStyleDelta(ColourSchemeData colourScheme) {
  final isDark = colourScheme.brightness == Brightness.dark;

  // Off-state track: solid neutral gray. Sits between the background and
  // the thumb so the (near-white) thumb stands out.
  final offTrackColor = isDark
      ? RayOklch.fromComponents(0.45, 0.006, 115.0).toColor()
      : RayOklch.fromComponents(0.82, 0.006, 115.0).toColor();

  // On-state track: only the dark mode accent needs darkening (default ~0.78–
  // 0.82). Light mode's accent (~0.30–0.46) already contrasts with the white
  // thumb.
  final onTrackColor = isDark
      ? colourScheme.colours.accent.withLightness(0.50).toColor()
      : null;

  return FSwitchStyleDelta.delta(
    trackColor: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.base(offTrackColor),
      if (onTrackColor != null)
        FVariantValueDeltaOperation.exact(
          {FSwitchVariantConstraint.selected},
          onTrackColor,
        ),
    ]),
  );
}
