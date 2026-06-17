import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';

/// The shared "eyebrow" section-label text style: small ([FTypography.xs]),
/// widely tracked, and meant to be rendered **uppercase by the caller**. The
/// case + scale shift alone marks a row as a heading a level above what it
/// groups, which frees weight and colour to keep carrying status and identity.
/// Callers layer on colour and the status weight (w400 idle / w600 active) and
/// uppercase the text themselves (render-only — never mutate the stored name).
///
/// `xs` ships a 0.2 letter-spacing tuned for sentence case; capitals need more
/// air, so the eyebrow widens tracking to 1.0 — the one net-new value in the
/// sidebar role-hierarchy treatment.
TextStyle eyebrowLabelStyle(FTypography typography) =>
    typography.xs.copyWith(letterSpacing: 1.0);

FSidebarStyleDelta buildSidebarStyleDelta(
  FTypography typography,
  ColourSchemeData colourScheme,
  PlotIconSizes iconSizes,
) {
  return FSidebarStyleDelta.delta(
    groupStyle: FSidebarGroupStyleDelta.delta(
      childrenPadding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
      padding: EdgeInsetsDelta.value(EdgeInsets.only(bottom: 20)),
      headerSpacing: 4,
      labelStyle: TextStyleDelta.value(
        eyebrowLabelStyle(typography).copyWith(
          color: colourScheme.foreground.withValues(alpha: 0.5),
          fontWeight: FontWeight.w600,
        ),
      ),
      actionStyle: FVariantsDelta.delta([
        FVariantOperation.all(
          IconThemeDataDelta.delta(size: iconSizes.xs),
        ),
      ]),
      itemStyle: FSidebarItemStyleDelta.delta(
        borderRadius: BorderRadius.circular(6),
        padding: EdgeInsetsGeometryDelta.value(
          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        textStyle: FVariants<FTappableVariantConstraint, FTappableVariant,
            TextStyle, TextStyleDelta>.all(typography.md),
      ),
    ),
  );
}
