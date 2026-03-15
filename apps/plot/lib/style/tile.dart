import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

FVariantsDelta<FItemVariantConstraint, FItemVariant, FTileStyle,
    FTileStyleDelta> buildTileStylesDelta(FColors colors) {
  return FVariantsDelta.delta([
    FVariantOperation.all(
      FTileStyleDelta.delta(
        backgroundColor: FVariantsValueDelta.delta([
          FVariantValueDeltaOperation.all(const Color(0x00000000)),
          FVariantValueDeltaOperation.exact(
            {
              FTappableVariantConstraint.selected
                  .and(FTappableVariantConstraint.hovered),
            },
            colors.primaryForeground,
          ),
          FVariantValueDeltaOperation.exact(
            {
              FTappableVariantConstraint.selected
                  .and(FTappableVariantConstraint.pressed),
            },
            colors.primaryForeground,
          ),
        ]),
      ),
    ),
  ]);
}
