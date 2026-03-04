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
