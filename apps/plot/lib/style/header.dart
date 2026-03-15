import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FVariantsDelta<FHeaderVariantConstraint, FHeaderVariant, FHeaderStyle,
    FHeaderStyleDelta> buildHeaderStylesDelta(
  FTypography typography,
  ColourSchemeData colourScheme,
) {
  return FVariantsDelta.delta([
    FVariantOperation.exact(
      {FHeaderVariantConstraint.root},
      FHeaderStyleDelta.delta(
        titleTextStyle: TextStyleDelta.value(
          typography.md.copyWith(
            color: colourScheme.muted,
            fontWeight: FontWeight.w500,
            height: 1,
          ),
        ),
        actionSpacing: 0,
      ),
    ),
  ]);
}
