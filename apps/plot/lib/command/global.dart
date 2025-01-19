import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'command.dart';

class GlobalCommands extends Commands {
  static final List<Command> all = [
    ChangePriority(),
  ];

  GlobalCommands() : super(title: 'Run a command', prompt: 'Search commands');

  @override
  Future<List<CommandGroup>> list({String? search}) async {
    return [CommandGroup(title: 'Recent', commands: all)];
  }
}

class ShowGlobalCommands extends ShowCommand<void> {
  ShowGlobalCommands()
      : super(
          title: 'Run a command',
          commands: (context) => GlobalCommands(),
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyK,
            meta: true,
          ),
        );
}

class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: (GlobalCommands.all + [ShowGlobalCommands()]).fold(
        <ShortcutActivator, VoidCallback>{},
        (bindings, command) => command.shortcut == null
            ? bindings
            : {
                ...bindings,
                command.shortcut!: () => context.run(command),
              },
      ),
      child: child,
    );
  }
}
