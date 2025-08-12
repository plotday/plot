import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/widget/colour_scheme.dart';

const widgetPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 12);
const widgetPaddingSm = EdgeInsets.symmetric(horizontal: 12, vertical: 8);

FThemeData buildTheme(ColourSchemeData colourScheme) {
  final colorScheme = colourScheme.toFColorScheme();
  var theme = FThemeData(
    colors: colorScheme,
    typography: FTypography.inherit(colors: colorScheme).copyWith(
      base: FTypography.inherit(
        colors: colorScheme,
      ).base.copyWith(fontSize: 12),
    ),
  );
  theme = theme.copyWith(
    headerStyles: theme.headerStyles.copyWith(
      // ignore: unused_result
      rootStyle: theme.headerStyles.rootStyle.copyWith(
        titleTextStyle: theme.typography.xl.copyWith(
          color: colourScheme.foreground,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    ),
    textFieldStyle: theme.textFieldStyle.copyWith(
      cursorColor: colourScheme.accent,
      contentTextStyle: theme.textFieldStyle.contentTextStyle.map(
        (style) => style.copyWith(color: colourScheme.foreground),
      ),
    ),
    buttonStyles: theme.buttonStyles.copyWith(
      // ignore: unused_result
      primary: theme.buttonStyles.primary.copyWith(
        // ignore: unused_result
        contentStyle: theme.buttonStyles.primary.contentStyle.copyWith(
          padding: widgetPadding,
          // textStyle: theme.buttonStyles.primary.contentStyle.textStyle.map(
          //   (style) => style.copyWith(color: colourScheme.foreground),
          // ),
        ),
      ),
      // ignore: unused_result
      outline: theme.buttonStyles.outline.copyWith(
        // enabledBoxDecoration: theme.buttonStyles.outline.enabledBoxDecoration
        //     .copyWith(border: Border.all(color: theme.colorScheme.border)),
        // disabledBoxDecoration: theme.buttonStyles.outline.disabledBoxDecoration
        //     .copyWith(border: Border.all(color: theme.colorScheme.border)),
        // enabledHoverBoxDecoration: theme
        //     .buttonStyles
        //     .outline
        //     .enabledHoverBoxDecoration
        //     .copyWith(border: Border.all(color: theme.colorScheme.border)),
        // ignore: unused_result
        contentStyle: theme.buttonStyles.outline.contentStyle.copyWith(
          // enabledTextStyle: theme
          //     .buttonStyles
          //     .outline
          //     .contentStyle
          //     .enabledTextStyle
          //     .copyWith(color: theme.colorScheme.foreground),
          // enabledIconColor: theme.colorScheme.foreground,
          padding: widgetPadding,
        ),
      ),
      // ignore: unused_result
      ghost: theme.buttonStyles.ghost.copyWith(
        // ignore: unused_result
        contentStyle: theme.buttonStyles.ghost.contentStyle.copyWith(
          // enabledTextStyle: theme
          //     .buttonStyles
          //     .outline
          //     .contentStyle
          //     .enabledTextStyle
          //     .copyWith(color: theme.colorScheme.foreground),
          // enabledIconColor: theme.colorScheme.foreground,
          padding: widgetPadding,
        ),
      ),
    ),
  );
  return theme;
}
