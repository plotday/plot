import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:platform_builder/platform_builder.dart';

extension type ThemeColor(int index) {
  const ThemeColor.defaultColor() : index = 0;

  Color? getBackground(BuildContext context) => PlatformResolver.current(
        defaultResolver: () {
          return context.theme.colorScheme.primary;
        },
      );

  Color? getForeground(BuildContext context) => PlatformResolver.current(
        defaultResolver: () {
          return context.theme.colorScheme.primary;
        },
      );
}
