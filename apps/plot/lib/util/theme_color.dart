import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:platform_builder/platform_builder.dart';

extension type ThemeColor(int index) {
  const ThemeColor.defaultColor() : index = 0;

  Color? getBackground(BuildContext context) => PlatformResolver.current(
        defaultResolver: () {
          return material.Colors.blue.shade900;
        },
      );

  Color? getForeground(BuildContext context) => PlatformResolver.current(
        defaultResolver: () {
          return material.Colors.blue;
        },
      );
}
