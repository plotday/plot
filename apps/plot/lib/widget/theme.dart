import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/widget/colour_scheme.dart';

FThemeData buildTheme(ColourSchemeData colourScheme) {
  final colorScheme = colourScheme.toFColorScheme();
  var theme = FThemeData(
    colorScheme: colorScheme,
    typography: FTypography.inherit(
      colorScheme: colorScheme,
    ).transform((t) => t.copyWith(base: t.base.copyWith(fontSize: 12))),
  );
  theme = theme.copyWith(
    textFieldStyle: theme.textFieldStyle.copyWith(
      enabledStyle: theme.textFieldStyle.enabledStyle.copyWith(
        contentTextStyle: theme.textFieldStyle.enabledStyle.contentTextStyle
            .copyWith(color: colourScheme.foreground),
      ),
    ),
    buttonStyles: theme.buttonStyles.copyWith(
      primary: theme.buttonStyles.primary.copyWith(
        contentStyle: theme.buttonStyles.primary.contentStyle.copyWith(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          enabledTextStyle:
              theme.buttonStyles.primary.contentStyle.enabledTextStyle
                  .copyWith(),
        ),
      ),
      outline: theme.buttonStyles.outline.copyWith(
        enabledBoxDecoration: theme.buttonStyles.outline.enabledBoxDecoration
            .copyWith(border: Border.all(color: theme.colorScheme.border)),
        disabledBoxDecoration: theme.buttonStyles.outline.disabledBoxDecoration
            .copyWith(border: Border.all(color: theme.colorScheme.border)),
        enabledHoverBoxDecoration: theme
            .buttonStyles
            .outline
            .enabledHoverBoxDecoration
            .copyWith(border: Border.all(color: theme.colorScheme.border)),
        contentStyle: theme.buttonStyles.outline.contentStyle.copyWith(
          enabledTextStyle: theme
              .buttonStyles
              .outline
              .contentStyle
              .enabledTextStyle
              .copyWith(color: theme.colorScheme.foreground),
          enabledIconColor: theme.colorScheme.foreground,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
      ghost: theme.buttonStyles.ghost.copyWith(
        contentStyle: theme.buttonStyles.ghost.contentStyle.copyWith(
          enabledTextStyle: theme
              .buttonStyles
              .outline
              .contentStyle
              .enabledTextStyle
              .copyWith(color: theme.colorScheme.foreground),
          enabledIconColor: theme.colorScheme.foreground,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
    ),
  );
  return theme;
}
