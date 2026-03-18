import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/global.dart';
import 'package:plot/page/loading.dart';
import 'app_context.dart';
import 'modal.dart';

@RoutePage(name: 'AppShellRoute')
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey _contextKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    AppContext.register(_contextKey);
  }

  @override
  void dispose() {
    AppContext.unregister(_contextKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FToaster(
      child: ModalProvider(
        child: Container(
          key: _contextKey,
          child: GlobalShortcuts(
            child: AutoRouter(placeholder: (context) => const LoadingPage()),
          ),
        ),
      ),
    );
  }
}
