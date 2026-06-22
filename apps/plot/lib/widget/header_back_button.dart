import 'package:flutter/widgets.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/window.dart';

/// The leading "←" chevron in the single-panel header (return from a thread, a
/// bare priority feed, or a new-thread step).
///
/// The glyph itself is small (18px) and sits centred in the 44px header band.
/// Previously the chevron's tap target was just the glyph plus a couple of
/// pixels of padding, leaving most of the band — vertically (the rest of the
/// 44px) and horizontally (the item-spacing gap to the next header item) —
/// inert. Taps that landed in that dead space did nothing, which made the
/// button fiddly to hit on mobile. This widget folds that otherwise-dead space
/// into the hit area **without** moving the glyph:
///
///  * Vertically it fills the full header height.
///  * Horizontally [endInset] adds trailing hit area so the inter-item spacing
///    the header would put between the chevron and the next item is absorbed
///    into the button instead. [startInset] does the same on the leading edge
///    for the header's content padding (the dead space between the screen edge
///    and the chevron). Callers that use either drop the matching outer
///    spacing/padding so the layout is unchanged — the gap simply becomes
///    tappable, and the glyph stays put.
///
/// The glyph rests at the muted tone and lifts to the hover foreground on
/// hover, matching every other icon button (see `Button._buildIconOnlyStyle`).
/// A bare [MouseRegion] (no cursor override) keeps the default desktop arrow
/// cursor — the chevron is a button, not a link.
class HeaderBackButton extends StatefulWidget {
  const HeaderBackButton({
    required this.onTap,
    this.startInset = 0,
    this.endInset = 0,
    super.key,
  });

  final VoidCallback onTap;

  /// Extra hit area folded onto the leading (left, in LTR) edge of the button.
  /// Used to absorb the header's leading content padding so the screen edge is
  /// tappable. Pushes the glyph right by the same amount, so callers drop that
  /// much header content padding to keep the glyph in place.
  final double startInset;

  /// Extra hit area folded onto the trailing (right, in LTR) edge of the
  /// button. Used to absorb the header's inter-item spacing so the gap to the
  /// next item is tappable. The glyph does not move.
  final double endInset;

  @override
  State<HeaderBackButton> createState() => _HeaderBackButtonState();
}

class _HeaderBackButtonState extends State<HeaderBackButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colour = context.colour;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          // Fill the full header band vertically so the inert padding above and
          // below the glyph becomes tappable. `widthFactor: 1` pins the width
          // to the glyph (plus its padding), so the icon and the item beside it
          // stay put.
          height: kAppHeaderHeight,
          child: Center(
            widthFactor: 1,
            child: Padding(
              padding: EdgeInsets.only(
                left: 2 + widget.startInset,
                right: 2 + widget.endInset,
              ),
              child: Icon(
                PlotIcon.left,
                size: 18,
                color: _hovered ? colour.hover : colour.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
