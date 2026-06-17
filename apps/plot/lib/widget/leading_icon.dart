import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/plot_icon_sizes.dart';

/// A leading icon centered in a fixed-width slot.
///
/// Use for any icon that sits before a label in a row — sidebar tiles, menu
/// items, picker options, compose rows. Two things make leading icons read as
/// "clean" rather than "crowded", and this widget bakes in both:
///
///  * **Size.** A glyph passed via [LeadingIcon.glyph] is drawn at the
///    cap-height-matched [PlotIconSizes.leading] size rather than 1:1 with the
///    label (the old default, since `iconSizes.base` equals the `md` font
///    size), so it sits optically level with the text instead of looming over
///    it.
///  * **Alignment.** The child is centered in a fixed-width square ([slotWidth],
///    defaulting to `iconSizes.base`). Centering glyphs of differing intrinsic
///    width in a shared-width slot keeps every row's label pinned to the same
///    x — left-aligning raw glyphs instead leaves labels looking ragged. The
///    slot is a touch wider than the cap-height glyph, giving it air.
///
/// Pass an arbitrary [child] (avatar, logo, SVG) via the default constructor,
/// or a single glyph via [LeadingIcon.glyph] to get the leading size for free.
class LeadingIcon extends StatelessWidget {
  const LeadingIcon({
    required this.child,
    this.slotWidth,
    this.padding,
    super.key,
  });

  /// Builds an [Icon] for [icon] at the cap-height-matched leading size
  /// ([size] overrides it) and centers it in the slot.
  LeadingIcon.glyph(
    IconData icon, {
    Color? color,
    double? size,
    this.slotWidth,
    this.padding,
    super.key,
  }) : child = _LeadingGlyph(icon: icon, color: color, size: size);

  /// The leading content: a glyph from [LeadingIcon.glyph], or any widget
  /// (avatar, logo) via the default constructor.
  final Widget child;

  /// Width and height of the square slot the [child] is centered in. Defaults
  /// to `iconSizes.base`, leaving a cap-height glyph some breathing room.
  final double? slotWidth;

  /// Optional outer padding around the slot (e.g. the sidebar's lg/md insets).
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final size = slotWidth ?? context.theme.iconSizes.base;
    Widget slot = SizedBox.square(dimension: size, child: Center(child: child));
    if (padding != null) slot = Padding(padding: padding!, child: slot);
    return slot;
  }
}

/// An [Icon] sized to the ambient cap-height leading size by default. Kept
/// private — callers build glyph leading icons through [LeadingIcon.glyph].
class _LeadingGlyph extends StatelessWidget {
  const _LeadingGlyph({required this.icon, this.color, this.size});

  final IconData icon;
  final Color? color;
  final double? size;

  @override
  Widget build(BuildContext context) => Icon(
    icon,
    size: size ?? context.theme.iconSizes.leading,
    color: color,
  );
}
