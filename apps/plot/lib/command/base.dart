import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show Value;

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

class CommandMessage extends CommandReturn {
  CommandMessage(this.message, {this.isError = false});
  final String message;
  final bool isError;
}

abstract class Command {
  const Command({
    required this.title,
    this.subtitle,
    this.description,
    this.icon,
    this.shortcut,
  });

  final String title;
  final String? subtitle;
  final String? description;
  final IconData? icon;
  final ShortcutActivator? shortcut;

  Future<CommandReturn?> run(BuildContext context);
}

class CommandWrapper extends Command {
  final Command command;
  final Future<CommandReturn?> Function(BuildContext context) _run;

  CommandWrapper(
    this.command, {
    required Future<CommandReturn?> Function(BuildContext context) run,
  }) : _run = run,
       super(
         title: command.title,
         subtitle: command.subtitle,
         description: command.description,
         icon: command.icon,
         shortcut: command.shortcut,
       );

  @override
  Future<CommandReturn?> run(BuildContext context) {
    return _run(context);
  }
}

/// A command for returning a value
class ValueCommand<T> extends Command {
  ValueCommand({
    required super.title,
    super.subtitle,
    super.description,
    super.icon,
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
  Future<CommandValue<T>?> run(BuildContext context) async {
    try {
      final value = await CommandBar.show<T>(context, commands(context));
      if (context.mounted && value.present) {
        onSelect(context, value.value);
        return CommandValue(value.value);
      }
      return null;
    } on Error catch (e) {
      print(e);
      print(e.stackTrace);
      rethrow;
    }
  }

  void onSelect(BuildContext context, T value) {}
}

extension BuildContextCommandExtension on BuildContext {
  Future<Value<T>> run<T>(Command command) async {
    final next = await command.run(this);
    if (next is CommandValue<T>) {
      return Value(next.value);
    } else if (next is CommandCommands<T>) {
      return await CommandBar.show<T>(this, next.commands);
    } else if (next is CommandPage) {
      await Dialog.show<void>(context: this, builder: (context) => next.child);
    }
    return Value.absent();
  }
}

abstract class CommandGroup {
  CommandGroup({required this.title, this.subtitle});

  final String title;
  final String? subtitle; // count

  Future<List<Command>> list({String? search});

  static List<Command> filter(List<Command> commands, String? search) {
    if (search == null || search.isEmpty) {
      return commands;
    }

    String searchLower = search.toLowerCase();
    bool match(String? field) {
      if (field == null) return false;
      return RegExp(
        '\\b${RegExp.escape(searchLower)}',
      ).hasMatch(field.toLowerCase());
    }

    return commands
        .where(
          (command) =>
              match(command.title) ||
              match(command.subtitle) ||
              match(command.description),
        )
        .toList()
      ..sort((a, b) {
        int aScore =
            match(a.title)
                ? 3
                : match(a.subtitle)
                ? 2
                : 1;
        int bScore =
            match(b.title)
                ? 3
                : match(b.subtitle)
                ? 2
                : 1;
        return bScore.compareTo(aScore);
      });
  }
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
    return CommandGroup.filter(commands, search);
  }
}

class Commands<T> {
  const Commands({
    required this.prompt,
    required this.groups,
    this.secondaryCommand,
  });

  final String prompt;
  final List<CommandGroup> groups;
  final Command? Function(String promptValue)? secondaryCommand;

  Future<Value<T>> show(BuildContext context) async {
    try {
      return await CommandBar.show<T>(
        context,
        this,
        secondaryCommand: secondaryCommand,
      );
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
  const CommandScope({required this.commands, required this.child, super.key});

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
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                  () => commands.show(context),
            },
            (bindings, command) =>
                command.shortcut == null
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
