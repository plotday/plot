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
    textFieldStyle: buildTextFieldStyle(
      theme.textFieldStyle,
      colourScheme,
      theme.style.borderRadius,
      theme.style.borderWidth,
    ),
    buttonStyles: buildButtonStyles(
      theme.buttonStyles,
      colourScheme,
      theme.style.borderRadius,
      typography,
    ),
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

FThemeData darkenTheme(FThemeData theme, ColourSchemeData colourScheme) {
  return buildTheme(
    colourScheme.copyWith(
      darken: colourScheme.brightness == .light ? 1.02 : 1.1,
    ),
  );
}
