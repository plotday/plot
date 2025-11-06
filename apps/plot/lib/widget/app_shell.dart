import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/action/global.dart';
import 'global_menu.dart';
import 'dialog.dart';

@RoutePage(name: 'AppShellRoute')
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return DialogProvider(
      child: GlobalMenu(child: GlobalShortcuts(child: const AutoRouter())),
    );
  }
}
