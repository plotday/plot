import 'package:flutter/widgets.dart';

import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CommandScope(
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
    );
  }
}
