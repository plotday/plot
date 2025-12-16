import 'package:flutter/widgets.dart';

const widgetPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 12);
const widgetPaddingSm = EdgeInsets.symmetric(horizontal: 12, vertical: 6);

// Border radius
const borderRadiusSm = 4.0;
const borderRadiusMd = 8.0;
const tileBorderRadius = BorderRadius.all(Radius.circular(borderRadiusSm));
const editorBorderRadius = BorderRadius.all(Radius.circular(borderRadiusMd));

// Form tile layout constants
const formTileLabelWidth = 80.0;
const formTileSpacer = 10.0;
const formTileSplitPoint =
    formTileLabelWidth +
    12.0 +
    formTileSpacer; // 102px (label + padding + spacer)
