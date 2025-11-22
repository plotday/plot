import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/layout.dart';

FButtonStyles buildButtonStyles(FButtonStyles baseStyles) {
  return baseStyles.copyWith(
    // ignore: unused_result
    primary: baseStyles.primary.copyWith(
      // ignore: unused_result
      contentStyle: baseStyles.primary.contentStyle.copyWith(
        padding: widgetPadding,
        textStyle: baseStyles.primary.contentStyle.textStyle.map(
          (style) => style.copyWith(color: Color(0xFFFFFFFF)),
        ),
      ),
    ),
    // ignore: unused_result
    outline: baseStyles.outline.copyWith(
      // enabledBoxDecoration: baseStyles.outline.enabledBoxDecoration
      //     .copyWith(border: Border.all(color: theme.colorScheme.border)),
      // disabledBoxDecoration: baseStyles.outline.disabledBoxDecoration
      //     .copyWith(border: Border.all(color: theme.colorScheme.border)),
      // enabledHoverBoxDecoration: baseStyles
      //     .outline
      //     .enabledHoverBoxDecoration
      //     .copyWith(border: Border.all(color: theme.colorScheme.border)),
      // ignore: unused_result
      contentStyle: baseStyles.outline.contentStyle.copyWith(
        // enabledTextStyle: baseStyles
        //     .outline
        //     .contentStyle
        //     .enabledTextStyle
        //     .copyWith(color: theme.colorScheme.foreground),
        // enabledIconColor: theme.colorScheme.foreground,
        padding: widgetPadding,
      ),
    ),
    // ignore: unused_result
    ghost: baseStyles.ghost.copyWith(
      // ignore: unused_result
      contentStyle: baseStyles.ghost.contentStyle.copyWith(
        // enabledTextStyle: baseStyles
        //     .outline
        //     .contentStyle
        //     .enabledTextStyle
        //     .copyWith(color: theme.colorScheme.foreground),
        // enabledIconColor: theme.colorScheme.foreground,
        padding: widgetPadding,
      ),
    ),
  );
}
