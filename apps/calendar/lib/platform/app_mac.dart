import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

import 'package:plot/widget/global_menu.dart';

class MacApp extends StatelessWidget {
  static Future<void> init() async {
    await const macos.MacosWindowUtilsConfig().apply();
  }

  const MacApp(this.router, {super.key});

  final RouterConfig<Object> router;

  @override
  Widget build(BuildContext context) {
    return GlobalMenu(
        child: macos.MacosApp.router(
      title: 'Plot',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
    ));
  }
}
