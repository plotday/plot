import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/typography.dart';
import 'package:plot/style/header.dart';
import 'package:plot/style/text_field.dart';
import 'package:plot/style/button.dart';
import 'package:plot/style/sidebar.dart';
import 'package:plot/style/tile.dart';
import 'package:plot/style/scaffold.dart';

FThemeData buildTheme(ColourSchemeData colourScheme) {
  final colorScheme = colourScheme.toFColorScheme();
  final typography = buildTypography(colorScheme);

  final plotColors = PlotColors(
    barrier: colourScheme.barrier,
    muted: colourScheme.muted,
    highlight: colourScheme.highlight,
    editableBackground: colourScheme.editableBackground,
  );

  var theme = FThemeData(
    colors: colorScheme,
    typography: typography,
    extensions: [plotColors],
  );

  theme = theme.copyWith(
    headerStyles: buildHeaderStyles(
      theme.headerStyles,
      typography,
      colourScheme,
    ),
    textFieldStyle: buildTextFieldStyle(theme.textFieldStyle, colourScheme),
    buttonStyles: buildButtonStyles(theme.buttonStyles),
    sidebarStyle: buildSidebarStyle(
      theme.sidebarStyle,
      typography,
      colourScheme,
    ),
    tileStyle: buildTileStyle(theme.tileStyle, theme.colors),
    scaffoldStyle: scaffoldStyle(style: theme.style, colors: theme.colors),
  );

  return theme;
}

/// Creates a darker variant of the theme for use in the first panel
FThemeData darkenTheme(FThemeData theme) {
  final colors = theme.colors;
  final plotColors = theme.plotColors;

  // Helper to darken a color by reducing lightness
  Color darken(Color color, [double factor = 0.92]) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness * factor).clamp(0.0, 1.0))
        .toColor();
  }

  final darkerColors = colors.copyWith(
    background: darken(colors.background),
    foreground: darken(colors.foreground),
    primary: darken(colors.primary),
    primaryForeground: darken(colors.primaryForeground),
    secondary: darken(colors.secondary),
    secondaryForeground: darken(colors.secondaryForeground),
    muted: darken(colors.muted),
    mutedForeground: darken(colors.mutedForeground),
    border: darken(colors.border),
    // Keep destructive/error colors unchanged for visibility
  );

  final darkerPlotColors = plotColors.copyWith(
    barrier: darken(plotColors.barrier),
    muted: darken(plotColors.muted),
    highlight: darken(plotColors.highlight),
    editableBackground: darken(plotColors.editableBackground),
  );

  // Recreate scaffoldStyle with darkened colors
  final darkerScaffoldStyle = scaffoldStyle(
    colors: darkerColors,
    style: theme.style,
  );

  return theme.copyWith(
    colors: darkerColors,
    extensions: [darkerPlotColors],
    scaffoldStyle: darkerScaffoldStyle,
  );
}
