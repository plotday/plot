import 'package:forui/forui.dart';

import 'package:plot/style/colors.dart';
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

  var theme = FThemeData(colors: colorScheme, typography: typography);

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
