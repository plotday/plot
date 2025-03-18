import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'package:plot/widget/widget.dart';

sealed class CommandReturn {}

class CommandValue<T> extends CommandReturn {
  CommandValue(this.value);
  final T value;
}

class CommandCommands<T> extends CommandReturn {
  CommandCommands(this.commands);
  final Commands<T> commands;
}

class CommandPage extends CommandReturn {
  CommandPage(this.child);
  final Widget child;
}

abstract class Command {
  const Command({
    required this.title,
    this.description,
    this.icon,
    this.shortcut,
  });

  final String title;
  final String? description;
  final IconData? icon;
  final ShortcutActivator? shortcut;

  Future<CommandReturn?> run(BuildContext context);
}

/// A command for returning a value
class ValueCommand<T> extends Command {
  ValueCommand({
    required super.title,
    super.description,
    required super.icon,
    required this.value,
  });

  final T value;

  @override
  Future<CommandValue<T>> run(BuildContext context) =>
      Future.value(CommandValue(value));
}

/// A command for showing a set of options and returning a value
class ShowCommand<T> extends Command {
  ShowCommand({
    required super.title,
    super.description,
    super.icon,
    super.shortcut,
    required this.commands,
  });

  final Commands<T> Function(BuildContext context) commands;

  @override
  Future<CommandValue<T?>> run(BuildContext context) async {
    try {
      final value = await CommandBar.show<T>(
        context,
        commands(context),
      );
      if (context.mounted && value != null) {
        onSelect(context, value);
      }
      return CommandValue(value);
    } on Error catch (e) {
      print(e);
      print(e.stackTrace);
      rethrow;
    }
  }

  void onSelect(BuildContext context, T value) {}
}

extension BuildContextCommandExtension on BuildContext {
  Future<T?> run<T>(Command command) async {
    final next = await command.run(this);
    if (next is CommandValue<T>) {
      return next.value;
    } else if (next is CommandCommands) {
      return await CommandBar.show<T>(this, next.commands);
    } else if (next is CommandPage) {
      await Dialog.show<void>(context: this, builder: (context) => next.child);
    }
    return null;
  }
}

abstract class CommandGroup {
  CommandGroup({
    required this.title,
    this.subtitle,
  });

  final String title;
  final String? subtitle; // count

  Future<List<Command>> list({String? search});
}

class StaticCommandGroup extends CommandGroup {
  StaticCommandGroup({
    required super.title,
    super.subtitle,
    required this.commands,
  });

  final List<Command> commands;

  @override
  Future<List<Command>> list({String? search}) async {
    if (search == null || search.isEmpty) {
      return commands;
    }
    String searchLower = search.toLowerCase();
    return commands
        .where((command) => command.title.toLowerCase().contains(searchLower))
        .toList();
  }
}

class Commands<T> {
  const Commands({
    required this.prompt,
    required this.groups,
  });

  final String prompt;
  final List<CommandGroup> groups;

  Future<T?> show(BuildContext context) async {
    try {
      return await CommandBar.show<T>(context, this);
    } on Error catch (e) {
      print(e);
      print(e.stackTrace);
      rethrow;
    }
  }

  Future<List<StaticCommandGroup>> list({String? search}) async {
    // Filter the commands based on the search query
    List<StaticCommandGroup> filteredCommandGroups = [];
    for (var group in groups) {
      // Filter commands within the group
      List<Command> matchingCommands = await group.list(search: search);

      // If any commands match, include the group with matching commands
      if (matchingCommands.isNotEmpty) {
        filteredCommandGroups.add(
          StaticCommandGroup(
            title: group.title,
            subtitle: group.subtitle,
            commands: matchingCommands,
          ),
        );
      }
    }
    return filteredCommandGroups;
  }
}

/// Activate new commands in the given widget scope. This adds a new scope for the CommandBar,
/// along with activating shortcuts for the commands.
class CommandScope extends StatelessWidget {
  const CommandScope({
    required this.commands,
    required this.child,
    super.key,
  });

  final Commands<void> commands;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: commands.groups
          .whereType<StaticCommandGroup>()
          .expand((group) => group.commands)
          .fold(
        <ShortcutActivator, VoidCallback>{
          const SingleActivator(
            LogicalKeyboardKey.keyK,
            meta: true,
          ): () => commands.show(context),
        },
        (bindings, command) => command.shortcut == null
            ? bindings
            : {
                ...bindings,
                command.shortcut!: () {
                  try {
                    context.run<void>(command);
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
