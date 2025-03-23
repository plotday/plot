import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:auto_route/auto_route.dart';

import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          var focusContext = FocusManager.instance.primaryFocus?.context;
          if (focusContext != null) {
            context = focusContext;
          }
          context.router.maybePop();
        },
      },
      child: CommandScope(
        commands: Commands(
          prompt: 'Run a command',
          groups: [
            StaticCommandGroup(title: 'Recent', commands: [
              PickCurrentActivity(),
              ShowSettings(),
            ])
          ],
        ),
        child: child,
      ),
    );
  }
}
