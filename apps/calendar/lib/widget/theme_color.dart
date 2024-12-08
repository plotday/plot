import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:platform_builder/platform_builder.dart';

extension type ThemeColor(int index) {
  factory ThemeColor.defaultColor() => ThemeColor(0);

  Color getBackground(BuildContext context) => PlatformResolver.current(
        defaultResolver: () {
          return material.ListTileTheme.of(context).tileColor!;
        },
      );
}
