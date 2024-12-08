import 'package:flutter/widgets.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:macos_window_utils/macos_window_utils.dart' as macos_win;
import 'package:macos_window_utils/macos/ns_window_button_type.dart';

class AppWidget extends StatelessWidget {
  static late final double toolbarHeight;
  static late final EdgeInsetsGeometry toolbarPadding;

  static Future<void> init() async {
    if (Platform.instance.isMacOS) {
      await const macos.MacosWindowUtilsConfig(
        toolbarStyle: macos.NSWindowToolbarStyle.unifiedCompact,
      ).apply();
      toolbarHeight = await macos_win.WindowManipulator.getTitlebarHeight();
      final lastWindowButtonPos =
          await macos_win.WindowManipulator.getStandardWindowButtonPosition(
        buttonType: NSWindowButtonType.zoomButton,
      );
      toolbarPadding = EdgeInsets.only(
        left: lastWindowButtonPos.right + 8.0,
      );
    } else {
      toolbarHeight = 32.0;
    }
  }

  const AppWidget({this.routerConfig, this.home, super.key});

  final RouterConfig<Object>? routerConfig;
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      builder: (context) => AdaptiveTheme(
        light: material.ThemeData(
          colorScheme: material.ColorScheme.fromSeed(
            seedColor: const Color(0x002BDD66),
            brightness: material.Brightness.light,
          ),
        ),
        dark: material.ThemeData(
          colorScheme: material.ColorScheme.fromSeed(
            seedColor: const Color(0x002BDD66),
            brightness: material.Brightness.dark,
          ),
        ),
        debugShowFloatingThemeButton: true,
        initial: AdaptiveThemeMode.system,
        builder: (theme, darkTheme) => material.MaterialApp.router(
          title: 'Plot',
          theme: theme,
          darkTheme: darkTheme,
          routerConfig: routerConfig,
        ),
      ),
      macOSBuilder: (context) => routerConfig == null
          ? macos.MacosApp(home: home)
          : macos.MacosApp.router(
              title: 'Plot',
              debugShowCheckedModeBanner: false,
              routerConfig: routerConfig,
            ),
    );
  }
}
