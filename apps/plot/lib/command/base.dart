import 'package:flutter/widgets.dart';

import 'package:plot/widget/widget.dart';

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

  Widget build(
    BuildContext context, {
    bool selected = false,
    void Function()? onTap,
  }) =>
      ListTile(
        leading: icon,
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle!) : null,
        selected: selected,
        onTap: onTap,
      );
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
    try {
      final value = await CommandBar.show<T>(
        context,
        commands(context),
      );
      if (context.mounted) {
        onSelect(context, value);
      }
      return CommandValue(value);
    } on Error catch (e) {
      print(e);
      print(e.stackTrace);
      rethrow;
    }
  }

  void onSelect(BuildContext context, T? value) {}
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
