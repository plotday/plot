import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';

FTextFieldStyleDelta buildTextFieldStyleDelta(
  ColourSchemeData colourScheme,
  FBorderRadius borderRadius,
  double borderWidth,
  FTypography typography,
) {
  return FTextFieldStyleDelta.delta(
    cursorColor: colourScheme.muted,
    color: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.all(const Color(0x00000000)),
      FVariantValueDeltaOperation.exact({
        FTextFieldVariantConstraint.focused,
      }, colourScheme.editableBackground),
    ]),
    border: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.all(
        OutlineInputBorder(
          borderSide: BorderSide(
            color: colourScheme.border,
            width: borderWidth,
          ),
          borderRadius: borderRadius.md,
        ),
      ),
      FVariantValueDeltaOperation.exact(
        {FTextFieldVariantConstraint.focused},
        OutlineInputBorder(
          borderSide: BorderSide(
            color: colourScheme.accent,
            width: borderWidth,
          ),
          borderRadius: borderRadius.md,
        ),
      ),
    ]),
    contentTextStyle: FVariantsDelta.delta([
      FVariantOperation.all(
        TextStyleDelta.delta(
          color: colourScheme.foreground,
          fontSize: typography.md.fontSize,
        ),
      ),
    ]),
  );
}
