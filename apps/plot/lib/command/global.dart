import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'command.dart';
import 'settings.dart';

class GlobalCommands extends Commands {
  static final List<Command> all = [
    ChangePriority(),
    ShowSettings(),
  ];

  GlobalCommands() : super(prompt: 'Run a command');

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
                command.shortcut!: () {
                  try {
                    context.run(command);
                  } catch (e) {
                    print('Error running command: $e');
                    rethrow;
                  }
                },
              },
      ),
      child: child,
    );
  }
}
