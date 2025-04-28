import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/router.dart';
import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          context.focusedRouter.maybePop();
        },
      },
      child: CommandScope(
        commands: Commands(
          prompt: 'Run a command',
          groups: [
            StaticCommandGroup(
              title: 'Commands',
              commands: [PickCurrentPriority(), ShowSettings()],
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}
