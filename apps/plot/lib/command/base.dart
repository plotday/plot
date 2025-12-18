import 'package:flutter/services.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/util/value.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/analytics/analytics.dart';
import 'provider.dart';
import 'logging.dart';

export 'package:plot/widget/form.dart';

sealed class CommandReturn {
  const CommandReturn();
}

// Command completed successfully
class CommandDone extends CommandReturn {
  const CommandDone();
}

// The user aborted the command (e.g. by pressing Escape)
class CommandSkipped extends CommandReturn {
  const CommandSkipped();
}

// Status message from running the command
class CommandMessage extends CommandReturn {
  const CommandMessage(this.message, {this.isError = false});
  final String message;
  final bool isError;
}

// Command is triggering navigation
class CommandRoute extends CommandReturn {
  const CommandRoute(this.route, {this.replace = false});
  final PageRouteInfo route;
  final bool replace;

  Future<void> go(BuildContext context) async {
    if (replace) {
      await context.router.root.replace(route);
    } else {
      await context.router.root.navigate(route);
    }
  }
}

abstract class Command {
  const Command({
    required this.title,
    required this.eventObject,
    required this.eventAction,
    this.subtitle,
    this.icon,
    this.hoverIcon,
    this.shortcut,
    this.on,
  });

  final String title;
  final EventObject eventObject;
  final EventAction eventAction;
  final String? subtitle;
  final IconData? icon;
  final IconData? hoverIcon;
  final ShortcutActivator? shortcut;
  // state for toggle actions
  final bool? on;

  Future<CommandReturn> run(BuildContext context);

  Widget? buildBody(BuildContext context) => null;
}

class CommandWrapper extends Command {
  final Command command;
  final Future<CommandReturn> Function(Command command, BuildContext context)?
  _run;

  CommandWrapper(
    this.command, {
    Future<CommandReturn> Function(Command command, BuildContext context)? run,
    Value<IconData?> icon = const Value<IconData?>.absent(),
    Value<IconData?> hoverIcon = const Value<IconData?>.absent(),
    String? title,
    Value<String?> subtitle = const Value<String?>.absent(),
  }) : _run = run,
       super(
         title: title ?? command.title,
         eventObject: command.eventObject,
         eventAction: command.eventAction,
         subtitle: subtitle.or(command.subtitle),
         icon: icon.or(command.icon),
         hoverIcon: hoverIcon.or(command.hoverIcon),
         shortcut: command.shortcut,
       );

  @override
  Future<CommandReturn> run(BuildContext context) {
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
    super.icon,
    super.shortcut,
    required this.commands,
    EventObject? eventObject,
    EventAction? eventAction,
  }) : super(
         eventObject: eventObject ?? EventObject.commandBar,
         eventAction: eventAction ?? EventAction.opened,
       );

  final Future<Commands> Function(BuildContext context) commands;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final commandsInstance = await commands(context);
      if (!context.mounted) {
        log.info(
          'Context no longer mounted, skipping CommandModal for "$title"',
        );
        return const CommandSkipped();
      }
      return await CommandModal(
        commandsInstance,
        rootContext: context,
      ).run(context);
    } on Error catch (e, t) {
      log.warning('Command "$title" failed', e, t);
      rethrow;
    }
  }
}

/// A command for showing a page widget in a dialog
class ShowPage extends Command {
  ShowPage({
    required super.title,
    super.icon,
    super.shortcut,
    required this.builder,
    EventObject? eventObject,
    EventAction? eventAction,
  }) : super(
         eventObject: eventObject ?? EventObject.modal,
         eventAction: eventAction ?? EventAction.opened,
       );

  final Widget Function(BuildContext context) builder;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final actionReturn = await Modal(
      builder: builder,
    ).show<CommandReturn>(context);
    return actionReturn.present ? actionReturn.value : const CommandSkipped();
  }
}

extension BuildContextCommandExtension on BuildContext {
  Future<void> run(Command command) async {
    // Start timing the command execution
    final startTime = DateTime.now();
    final commandType = command.runtimeType.toString();

    CommandReturn? result;
    String? errorType;
    String? errorMessage;
    bool success = true;

    try {
      result = await command.run(this);

      // Determine success based on CommandReturn type
      if (result is CommandMessage && result.isError) {
        success = false;
        errorMessage = result.message;
      }

      if (result is CommandMessage) {
        if (result.isError) {
          final colors = theme.colors;
          showFToast(
            context: this,
            alignment: FToastAlignment.topEnd,
            title: const Text('Error'),
            description: Text(result.message),
            duration: const Duration(seconds: 5),
            style: (style) => style.copyWith(
              decoration: style.decoration.copyWith(color: colors.destructive),
              iconStyle: style.iconStyle.copyWith(
                color: colors.destructiveForeground,
              ),
              titleTextStyle: style.titleTextStyle.copyWith(
                color: colors.destructiveForeground,
              ),
              descriptionTextStyle: style.descriptionTextStyle.copyWith(
                color: colors.destructiveForeground,
              ),
            ),
          );
        } else {
          showFToast(
            context: this,
            alignment: FToastAlignment.topEnd,
            title: Text(result.message),
            duration: const Duration(seconds: 3),
          );
        }
      } else if (result is CommandRoute) {
        await result.go(this);
      }
    } catch (e, stackTrace) {
      success = false;
      errorType = e.runtimeType.toString();
      errorMessage = e.toString();

      // Track error event using explicit enum values
      await Analytics.instance.trackError(
        command.eventObject.value,
        errorType: errorType,
        errorMessage: errorMessage,
        stackTrace: extractStackTrace(stackTrace),
        context: 'command_execution',
      );

      rethrow;
    } finally {
      // Calculate duration
      final durationMs = DateTime.now().difference(startTime).inMilliseconds;

      // Track command execution using explicit enum values
      await Analytics.instance.trackAction(
        command.eventObject,
        command.eventAction,
        buildActionProperties(
          actionType: commandType,
          success: success,
          durationMs: durationMs,
          errorType: errorType,
          errorMessage: errorMessage,
        ),
      );

      // Track performance issue if command took too long
      const performanceThresholdMs = 2000;
      if (durationMs > performanceThresholdMs) {
        await Analytics.instance.trackPerformance(
          object: EventObject.action,
          durationMs: durationMs,
          thresholdMs: performanceThresholdMs,
          operationType: commandType,
        );
      }
    }
  }
}

abstract class CommandGroup {
  CommandGroup({this.title, this.subtitle, this.infoBuilder, this.shortcut});

  final String? title;
  final String? subtitle; // count
  final Widget Function(BuildContext)? infoBuilder;
  final ShortcutActivator? shortcut;

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
        .where((command) => match(command.title) || match(command.subtitle))
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
    super.title,
    super.subtitle,
    super.infoBuilder,
    super.shortcut,
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

  Future<CommandReturn> show(BuildContext context) async {
    try {
      return await CommandModal(this, rootContext: context).run(context);
    } on Error catch (e, t) {
      log.warning('Error running command bar', e, t);
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
            infoBuilder: group.infoBuilder,
            shortcut: group.shortcut,
            commands: matchingCommands,
          ),
        );
      }
    }
    return filteredCommandGroups;
  }
}

/// Activate new commands in the given widget scope. This adds a new scope for the CommandModal,
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
    // Collect shortcuts from individual commands
    final commandBindings = widget.commands
        .expand((group) => group.commands)
        .fold<Map<ShortcutActivator, VoidCallback>>(
          {},
          (bindings, command) => command.shortcut == null
              ? bindings
              : {
                  ...bindings,
                  command.shortcut!: () {
                    try {
                      context.run(command);
                    } catch (e, t) {
                      log.warning('Error running command', e, t);
                      rethrow;
                    }
                  },
                },
        );

    // Collect shortcuts from command groups
    final groupBindings = widget.commands
        .fold<Map<ShortcutActivator, VoidCallback>>(
          {},
          (bindings, group) => group.shortcut == null
              ? bindings
              : {
                  ...bindings,
                  group.shortcut!: () {
                    try {
                      // Open CommandModal with only this group's commands
                      Commands(
                        prompt: group.title ?? 'Run a command',
                        groups: [group],
                      ).show(context);
                    } catch (e, t) {
                      log.warning('Error opening command group', e, t);
                      rethrow;
                    }
                  },
                },
        );

    return CallbackShortcuts(
      bindings: {
        // Global Cmd+K to open all commands
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            Commands(
              prompt: 'Run a command',
              groups: CommandRegistry.of(context).commands,
            ).show(context),
        // Merge command shortcuts and group shortcuts
        ...commandBindings,
        ...groupBindings,
      },
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
