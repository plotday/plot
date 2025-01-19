import 'package:flutter/widgets.dart';

import 'package:plot/widget/icon.dart';
import 'package:plot/widget/command_bar.dart';

sealed class CommandReturn {}

class CommandDone extends CommandReturn {
  CommandDone();
}

class CommandValue<T> extends CommandReturn {
  CommandValue(this.value);
  final T value;
}

class CommandCommands extends CommandReturn {
  CommandCommands(this.commands);
  final Commands commands;
}

class CommandPage extends CommandReturn {
  CommandPage(this.child);
  final Widget child;
}

abstract class Command {
  Command({
    required this.title,
    this.subtitle,
    this.icon,
    this.shortcut,
  });

  final String title;
  final String? subtitle; // type
  final PlotIcon? icon;
  final ShortcutActivator? shortcut;

  Future<CommandReturn> run(BuildContext context);
}

/// A command for returning a value
class ValueCommand<T> extends Command {
  ValueCommand({
    required super.title,
    super.subtitle,
    required super.icon,
    required this.value,
  });

  final T value;

  @override
  Future<CommandReturn> run(BuildContext context) =>
      Future.value(CommandValue(value));
}

/// A command for showing a set of options and returning a value
class ShowCommand<T> extends Command {
  ShowCommand({
    required super.title,
    super.subtitle,
    super.icon,
    super.shortcut,
    required this.commands,
  });

  final Commands Function(BuildContext context) commands;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final value = await CommandBar.show<T>(
      context,
      commands(context),
    );
    if (context.mounted) {
      onSelect(context, value);
    }
    return CommandValue(value);
  }

  void onSelect(BuildContext context, T? value) {}
}

extension BuildContextCommandExtension on BuildContext {
  void run(Command command) {
    command.run(this);
  }
}

class CommandGroup {
  CommandGroup({
    required this.title,
    this.subtitle,
    required this.commands,
  });

  final String title;
  final String? subtitle; // count
  final List<Command> commands;
}

abstract class Commands {
  Commands({
    required this.prompt,
  });

  final String prompt;

  Future<List<CommandGroup>> list({String? search});
}
