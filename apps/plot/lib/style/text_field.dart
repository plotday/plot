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
    // forui 0.22 introduced a default minHeight (36 for desktop md).
    // It expands the field beyond its intrinsic content and pushes the
    // text off-center in fixed-height containers (e.g. the unified
    // header) and modal search rows. Drop the floor — sizing is driven
    // by content + contentPadding, as it was pre-0.22.
    constraints: const BoxConstraints(),
    // Fill bordered fields with `editableBackground` in every state. An
    // unfocused field that fell back to the transparent page background read
    // as disabled (greyed-out) next to the white focused field. Borderless
    // fields used in special contexts (ghost/compose/header prompts) override
    // this back to transparent so the parent surface shows through.
    color: FVariantsValueDelta.delta([
      FVariantValueDeltaOperation.all(colourScheme.editableBackground),
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
    hintTextStyle: FVariantsDelta.delta([
      FVariantOperation.all(
        TextStyleDelta.delta(fontSize: typography.md.fontSize),
      ),
    ]),
  );
}
