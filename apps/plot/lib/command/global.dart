import 'package:flutter/widgets.dart';

import 'command.dart';

class GlobalShortcuts extends StatelessWidget {
  GlobalShortcuts({required this.child, super.key});

  final Widget child;
  final List<StaticCommandGroup> commands = [
    StaticCommandGroup(
      title: 'Priorities',
      commands: [PickCurrentPriority(), NewPriority()],
    ),
    settingsCommands,
    accountCommands,
  ];

  @override
  Widget build(BuildContext context) {
    return CommandScope(commands: commands, child: child);
  }
}
