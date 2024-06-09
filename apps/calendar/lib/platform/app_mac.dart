import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class MacApp extends StatelessWidget {
  static Future<void> init() async {
    await const macos.MacosWindowUtilsConfig().apply();
  }

  const MacApp(this.router, {super.key});

  final RouterConfig<Object> router;

  @override
  Widget build(BuildContext context) {
    return macos.MacosApp.router(
      title: 'Plot',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    );
  }
}
