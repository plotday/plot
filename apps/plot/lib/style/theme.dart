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
    highlight: colourScheme.highlight,
    editableBackground: colourScheme.editableBackground,
  );

  var theme = FThemeData(
    colors: colorScheme,
    typography: typography,
    extensions: [plotColors, iconSizes, spacing],
  );

  final customTextFieldStyle = buildTextFieldStyle(
    theme.textFieldStyle,
    colourScheme,
    theme.style.borderRadius,
    theme.style.borderWidth,
  );

  theme = theme.copyWith(
    headerStyles: buildHeaderStyles(
      theme.headerStyles,
      typography,
      colourScheme,
    ),
    textFieldStyle: customTextFieldStyle,
    dateFieldStyle: (style) =>
        style.copyWith(textFieldStyle: customTextFieldStyle),
    timeFieldStyle: (style) =>
        style.copyWith(textFieldStyle: customTextFieldStyle),
    buttonStyles: buildButtonStyles(
      theme.buttonStyles,
      colourScheme,
      theme.style.borderRadius,
      typography,
      iconSizes,
    ),
    sidebarStyle: buildSidebarStyle(
      theme.sidebarStyle,
      typography,
      colourScheme,
      iconSizes,
    ),
    tileStyle: buildTileStyle(theme.tileStyle, theme.colors),
    scaffoldStyle: scaffoldStyle(style: theme.style, colors: theme.colors),
    bottomNavigationBarStyle: buildBottomNavigationBarStyle(
      theme.bottomNavigationBarStyle,
      colourScheme,
    ),
    toasterStyle: buildToasterStyle(
      theme.toasterStyle,
      colourScheme,
      theme.style.borderRadius,
      typography,
      iconSizes,
    ),
    tooltipStyle: buildTooltipStyle(
      theme.tooltipStyle,
      colourScheme,
      theme.style.borderRadius,
      typography,
    ),
    alertStyles: buildAlertStyles(
      theme.alertStyles,
      colourScheme,
      theme.style.borderRadius,
      typography,
      iconSizes,
    ),
  );

  return theme;
}

FThemeData darkenTheme(
  BuildContext context,
  FThemeData theme,
  ColourSchemeData colourScheme,
) {
  return buildTheme(
    context,
    colourScheme.copyWith(
      darken: colourScheme.brightness == .light ? 1.02 : 1.1,
    ),
  );
}
