import 'dart:math' show pow;

import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/style/typography.dart';
import 'package:plot/style/header.dart';
import 'package:plot/style/text_field.dart';
import 'package:plot/style/button.dart';
import 'package:plot/style/sidebar.dart';
import 'package:plot/style/switch.dart';
import 'package:plot/style/tile.dart';
import 'package:plot/style/scaffold.dart';
import 'package:plot/style/bottom_navigation_bar.dart';
import 'package:plot/style/toaster.dart';
import 'package:plot/style/tooltip.dart';
import 'package:plot/style/alert.dart';

FThemeData buildTheme(BuildContext context, ColourSchemeData colourScheme) {
  final colorScheme = colourScheme.toFColorScheme();
  final typography = buildTypography(context, colorScheme);
  final iconSizes = buildIconSizes(context);
  final spacing = buildSpacing(context);

  final plotColors = PlotColors(
    barrier: colourScheme.barrier,
    muted: colourScheme.muted,
    veryMuted: colourScheme.veryMuted,
    highlight: colourScheme.highlight,
    editableBackground: colourScheme.editableBackground,
  );

  var theme = FThemeData(
    colors: colorScheme,
    typography: typography,
    touch: false,
    extensions: [plotColors, iconSizes, spacing],
  );

  // Override global style for warmer, softer appearance
  theme = theme.copyWith(
    style: FStyleDelta.delta(
      borderRadius: const FBorderRadius(),
      borderWidth: 0.5,
      tappableStyle: FTappableStyleDelta.delta(
        motion: FTappableMotion.none,
      ),
    ),
  );

  final textFieldStyleDelta = buildTextFieldStyleDelta(
    colourScheme,
    theme.style.borderRadius,
    theme.style.borderWidth,
    typography,
  );

  // Apply the text field style delta to all text field sizes
  final textFieldSizesDelta = FVariantsDelta<FTextFieldSizeVariantConstraint,
      FTextFieldSizeVariant, FTextFieldStyle, FTextFieldStyleDelta>.delta([
    FVariantOperation.all(textFieldStyleDelta),
  ]);

  theme = theme.copyWith(
    headerStyles: buildHeaderStylesDelta(typography, colourScheme),
    textFieldStyles: textFieldSizesDelta,
    dateFieldStyle: FDateFieldStyleDelta.delta(
      fieldStyles: textFieldSizesDelta,
    ),
    timeFieldStyle: FTimeFieldStyleDelta.delta(
      fieldStyles: textFieldSizesDelta,
    ),
    buttonStyles: buildButtonStylesDelta(
      theme.buttonStyles,
      colourScheme,
      theme.style.borderRadius,
      typography,
      iconSizes,
    ),
    sidebarStyle: buildSidebarStyleDelta(
      typography,
      colourScheme,
      iconSizes,
    ),
    switchStyle: buildSwitchStyleDelta(colourScheme),
    tileStyles: buildTileStylesDelta(theme.colors),
    scaffoldStyle: scaffoldStyle(
      style: theme.style,
      colors: theme.colors,
    ),
    bottomNavigationBarStyle: buildBottomNavigationBarStyleDelta(
      theme.bottomNavigationBarStyle,
      colourScheme,
    ),
    toasterStyle: buildToasterStyleDelta(
      colourScheme,
      theme.style.borderRadius,
      typography,
      iconSizes,
    ),
    tooltipStyle: buildTooltipStyleDelta(colourScheme, typography),
    alertStyles: buildAlertStylesDelta(
      colourScheme,
      typography,
      iconSizes,
    ),
    popoverMenuStyle: FPopoverMenuStyleDelta.delta(
      itemGroupStyle: FItemGroupStyleDelta.delta(
        itemStyles: FVariantsDelta.delta([
          FVariantOperation.all(
            FItemStyleDelta.delta(
              contentStyle: FItemContentStyleDelta.delta(
                prefixIconStyle: FVariants(
                  IconThemeData(
                    color: colorScheme.foreground,
                    size: 15,
                  ),
                  variants: {
                    [FTappableVariantConstraint.disabled]: IconThemeData(
                      color: colorScheme.disable(colorScheme.foreground),
                      size: 15,
                    ),
                  },
                ),
              ),
            ),
          ),
        ]),
      ),
    ),
  );

  return theme;
}

FThemeData darkenTheme(
  BuildContext context,
  FThemeData theme,
  ColourSchemeData colourScheme, {
  int steps = 1,
}) {
  final factor = colourScheme.brightness == Brightness.light ? 1.015 : 1.05;
  return buildTheme(
    context,
    colourScheme.copyWith(darken: pow(factor, steps).toDouble()),
  );
}
