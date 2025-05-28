import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/router.dart';
import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  GlobalShortcuts({required this.child, super.key});

  final Widget child;
  final List<StaticCommandGroup> commands = [
    StaticCommandGroup(
      title: 'Commands',
      commands: [PickCurrentPriority(), ShowSettings()],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          context.focusedRouter.maybePop();
        },
      },
      child: CommandScope(commands: commands, child: child),
    );
  }
}
