import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FVariantsDelta<FHeaderVariantConstraint, FHeaderVariant, FHeaderStyle,
    FHeaderStyleDelta> buildHeaderStylesDelta(
  FTypography typography,
  ColourSchemeData colourScheme,
) {
  return FVariantsDelta.delta([
    // forui 0.21 added a default BoxConstraints(minHeight: 54) (desktop) on
    // FHeader. Plot lets the title row drive header height across all
    // header variants, so reinstate "no minimum" once at the theme level.
    FVariantOperation.all(
      FHeaderStyleDelta.delta(constraints: const BoxConstraints()),
    ),
    FVariantOperation.exact(
      {FHeaderVariantConstraint.root},
      FHeaderStyleDelta.delta(
        titleTextStyle: TextStyleDelta.value(
          typography.md.copyWith(
            color: colourScheme.foreground,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
        actionSpacing: 0,
      ),
    ),
  ]);
}
