import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:widgetbook_annotation/widgetbook_annotation.dart' as widgetbook;
import 'package:flutter_driver/driver_extension.dart';

import 'package:plot/style/theme.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';

import 'main.directories.g.dart';

void main() {
  enableFlutterDriverExtension();
  runApp(const WidgetbookApp());
}

@widgetbook.App()
class WidgetbookApp extends StatelessWidget {
  const WidgetbookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Widgetbook(
        directories: directories,
        appBuilder: (context, child) {
          final colourScheme = _buildColourScheme(Brightness.light);
          return Provider<ColourSchemeData>.value(
            value: colourScheme,
            child: Builder(
              builder: (context) => FTheme(
                data: buildTheme(context, context.colour),
                child: ColoredBox(
                  color: colourScheme.background,
                  child: Center(child: child),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static ColourSchemeData _buildColourScheme(Brightness brightness) {
    return ColourSchemeData(
      themeColor: const ThemeColor.defaultColor(),
      brightness: brightness,
    );
  }
}
