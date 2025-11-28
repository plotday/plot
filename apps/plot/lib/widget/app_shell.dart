import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/command/global.dart';
import 'package:plot/page/loading.dart';
import 'global_menu.dart';
import 'modal.dart';

@RoutePage(name: 'AppShellRoute')
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return ModalProvider(
      child: GlobalMenu(
        child: GlobalShortcuts(
          child: AutoRouter(placeholder: (context) => const LoadingPage()),
        ),
      ),
    );
  }
}
