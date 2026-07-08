import 'package:flutter/widgets.dart';

// Border radius
const borderRadiusSm = 6.0;
const borderRadiusMd = 10.0;
const tileBorderRadius = BorderRadius.all(Radius.circular(borderRadiusSm));
const editorBorderRadius = BorderRadius.all(Radius.circular(borderRadiusMd));

// Form tile layout constants
const formTileLabelWidth = 80.0;
const formTileSpacer = 10.0;
const formTileSplitPoint =
    formTileLabelWidth +
    12.0 +
    formTileSpacer; // 102px (label + padding + spacer)

// Shared list-row leading metrics. One rhythm for the compose picker rows
// (NewThreadPage) and the roomy single-panel mobile focus sidebar, so both
// mobile lists present an item identically — same leading-glyph gutter, glyph
// size, and gutter→name gap — instead of drifting into a "close but not quite"
// mismatch. The compose pill constants (`composePill*`) alias these.
const double listRowGutter = 24; // widest leading glyph (avatar / count badge)
const double listRowIconSize = 16; // smaller glyphs: connector/twist logos, focus icons
const double listRowIconGap = 8; // gutter → name
