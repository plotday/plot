import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' as material;
import 'package:adaptive_theme/adaptive_theme.dart';

class MaterialApp extends StatelessWidget {
  const MaterialApp(this.router, {super.key});

  final RouterConfig<Object> router;

  @override
  Widget build(BuildContext context) {
    return AdaptiveTheme(
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
        routerConfig: router,
      ),
    );
  }
}
