import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/util/value.dart';
import 'package:plot/widget/widget.dart';
import 'provider.dart';
import 'logging.dart';

sealed class CommandReturn {}

class CommandPage extends CommandReturn {
  CommandPage(this.child);
  final Widget child;
}

class CommandMessage extends CommandReturn {
  CommandMessage(this.message, {this.isError = false});
  final String message;
  final bool isError;
}

class CommandRoute extends CommandReturn {
  CommandRoute(this.route, {this.replace = false});
  final PageRouteInfo route;
  final bool replace;
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

  Widget? buildBody(BuildContext context) => null;
}

class CommandWrapper extends Command {
  final Command command;
  final Future<CommandReturn?> Function(Command command, BuildContext context)?
  _run;

  CommandWrapper(
    this.command, {
    Future<CommandReturn?> Function(Command command, BuildContext context)? run,
    Value<IconData?> icon = const Value<IconData?>.absent(),
  }) : _run = run,
       super(
         title: command.title,
         subtitle: command.subtitle,
         description: command.description,
         icon: icon.or(command.icon),
         shortcut: command.shortcut,
       );

  @override
  Future<CommandReturn?> run(BuildContext context) {
    if (_run != null) {
      return _run(command, context);
    }
    return command.run(context);
  }

  @override
  Widget? buildBody(BuildContext context) => command.buildBody(context);
}

/// A command for showing a set of commands
class ShowCommands extends Command {
  ShowCommands({
    required super.title,
    super.description,
    super.icon,
    super.shortcut,
    required this.commands,
  });

  final Future<Commands> Function(BuildContext context) commands;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    try {
      final commandReturn = CommandBar(await commands(context));
      if (!context.mounted) return null;
      return await commandReturn.run(context);
    } on Error catch (e) {
      log.warning(e, e.stackTrace);
      rethrow;
    }
  }
}

/// A command for showing a page widget in a dialog
class ShowPage extends Command {
  ShowPage({
    required super.title,
    super.description,
    super.icon,
    super.shortcut,
    required this.builder,
  });

  final Widget Function(BuildContext context) builder;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandPage(builder(context));
  }
}

extension BuildContextCommandExtension on BuildContext {
  Future<void> run(Command command) async {
    final next = await command.run(this);
    if (next is CommandPage) {
      final pageResult = await Dialog(
        builder: (_) => next.child,
      ).show<CommandReturn?>(this);
      if (pageResult.present) {
        return await run(
          CommandWrapper(command, run: (_, __) async => pageResult.value),
        );
      }
    } else if (next is CommandRoute) {
      if (next.replace) {
        router.replace(next.route);
      } else {
        router.navigate(next.route);
      }
    }
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
        int aScore = match(a.title)
            ? 3
            : match(a.subtitle)
            ? 2
            : 1;
        int bScore = match(b.title)
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

class Commands {
  const Commands({String? prompt, required this.groups, this.secondaryCommand})
    : prompt = prompt ?? 'Run a command';

  final String prompt;
  final List<CommandGroup> groups;
  final Command? Function(String promptValue)? secondaryCommand;

  Future<CommandReturn?> show(BuildContext context) async {
    try {
      return await CommandBar(
        this,
        secondaryCommand: secondaryCommand,
      ).run(context);
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
class CommandScope extends StatefulWidget {
  const CommandScope({required this.commands, required this.child, super.key});

  final List<StaticCommandGroup> commands;
  final Widget child;

  @override
  CommandScopeState createState() => CommandScopeState();
}

class CommandScopeState extends State<CommandScope> {
  RegisterCommandGroups? register;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: widget.commands.expand((group) => group.commands).fold(
        <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              Commands(
                prompt: 'Run a command',
                groups: CommandRegistry.of(context).commands,
              ).show(context),
        },
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
      child: widget.child,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _register();
    });
  }

  @override
  void didUpdateWidget(covariant CommandScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  void _register() {
    if (register == null) {
      CommandRegistry registry = CommandRegistry.of(context);
      register = registry.register();
    }
    register!(widget.commands);
  }

  @override
  void dispose() {
    register?.call(null);
    super.dispose();
  }
}
