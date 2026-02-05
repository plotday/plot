import 'package:flutter/services.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/util/value.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/analytics/tracker.dart';
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
  const CommandMessage(this.message, {this.title, this.isError = false});
  final String message;
  final String? title;
  final bool isError;
}

// Command completed successfully and requests refresh of parent modal
class CommandRefresh extends CommandReturn {
  const CommandRefresh({this.message, this.title});

  /// Optional success message to show to the user
  final String? message;

  /// Optional title for the success message
  final String? title;
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

  /// Override to provide custom enabled logic based on context.
  /// Returns true by default (command is enabled).
  bool enabled(BuildContext context) => true;

  Future<CommandReturn> run(BuildContext context);

  /// Override to provide a custom icon widget (e.g., Avatar) instead of IconData.
  /// This is specifically for icon-only display and takes precedence over [icon].
  ///
  /// The [hoverIcon] parameter indicates whether the button is being hovered.
  /// Defaults to false (not hovering).
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) => null;

  /// Override to provide custom body content for the command in modals/lists.
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
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      command.buildIcon(context, hoverIcon: hoverIcon);

  @override
  Widget? buildBody(BuildContext context) => command.buildBody(context);
}

/// A command for showing a set of commands.
///
/// Provide either [commands] (static) or [commandsBuilder] (async/dynamic),
/// not both. Dynamic command lists automatically show the filter field on
/// mobile so users can search or create entries (e.g. invite by email).
class ShowCommands extends Command {
  ShowCommands({
    required super.title,
    super.icon,
    super.hoverIcon,
    super.shortcut,
    this.commands,
    this.commandsBuilder,
    EventObject? eventObject,
    EventAction? eventAction,
  }) : assert(
         (commands != null) != (commandsBuilder != null),
         'Provide either commands or commandsBuilder, not both',
       ),
       super(
         eventObject: eventObject ?? EventObject.commandBar,
         eventAction: eventAction ?? EventAction.opened,
       );

  final Commands? commands;
  final Future<Commands> Function(BuildContext context)? commandsBuilder;

  /// Whether this command list is dynamic (async builder).
  /// Dynamic lists always show the filter field on mobile.
  bool get isDynamic => commandsBuilder != null;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final commandsInstance =
          commands ?? await commandsBuilder!(context);
      if (!context.mounted) {
        log.info(
          'Context no longer mounted, skipping CommandModal for "$title"',
        );
        return const CommandSkipped();
      }
      return await CommandModal(
        commandsInstance,
        rootContext: context,
        showFilter: isDynamic ? true : null,
        commandsBuilder: commandsBuilder != null
            ? () => commandsBuilder!(context)
            : null,
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
  Future<CommandReturn> run(Command command) async {
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
          showToast(
            title: result.title,
            message: result.message,
            isError: true,
          );
        } else {
          showToast(title: result.title, message: result.message);
        }
      } else if (result is CommandRoute) {
        await result.go(this);
      }
    } catch (e, stackTrace) {
      success = false;
      errorType = e.runtimeType.toString();
      errorMessage = e.toString();

      // Track error event using explicit enum values
      await Tracker.trackError(
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
      await Tracker.trackAction(
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
        await Tracker.trackPerformance(
          object: EventObject.action,
          durationMs: durationMs,
          thresholdMs: performanceThresholdMs,
          operationType: commandType,
        );
      }
    }
    return result;
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

    // Split search into individual words
    List<String> searchWords = search.toLowerCase().trim().split(
      RegExp(r'\s+'),
    );

    bool match(String? field) {
      if (field == null) return false;
      String fieldLower = field.toLowerCase();

      // All search words must prefix match at least one word in the field
      return searchWords.every((searchWord) {
        // Split field into words and check if any word starts with searchWord
        return fieldLower.split(RegExp(r'[\s/]+')).any((fieldWord) {
          return fieldWord.startsWith(searchWord);
        });
      });
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
  const Commands({
    String? prompt,
    required this.groups,
    this.secondaryCommand,
    this.emptyMessage,
  }) : prompt = prompt ?? 'Run a command';

  final String prompt;
  final List<CommandGroup> groups;
  final Command? Function(String promptValue)? secondaryCommand;
  final String? emptyMessage;

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
///
/// Provide either [commands] (static list) or [commandsBuilder] (lazy builder), not both.
/// When using [commandsBuilder], optionally provide a [listenable] to trigger rebuilds.
///
/// Route-aware: automatically unregisters when the enclosing [ModalRoute] is no
/// longer current and re-registers when it becomes current again. This prevents
/// command accumulation when route pages are kept alive by the router.
class CommandScope extends StatefulWidget {
  const CommandScope({
    this.commands,
    this.commandsBuilder,
    this.listenable,
    required this.child,
    super.key,
  }) : assert(
         (commands != null) != (commandsBuilder != null),
         'Provide either commands or commandsBuilder, not both',
       );

  final List<StaticCommandGroup>? commands;
  final List<StaticCommandGroup> Function()? commandsBuilder;
  final Listenable? listenable;
  final Widget child;

  @override
  CommandScopeState createState() => CommandScopeState();
}

class CommandScopeState extends State<CommandScope> {
  RegisterCommandGroups? _register;
  List<StaticCommandGroup> _resolvedCommands = [];
  bool _routeActive = true;

  List<StaticCommandGroup> _resolveCommands() {
    return widget.commands ?? widget.commandsBuilder!();
  }

  /// Identity-based comparison: checks group titles and command titles/types.
  static bool _commandsEqual(
    List<StaticCommandGroup> a,
    List<StaticCommandGroup> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) {
        if (a[i].title != b[i].title) return false;
        if (a[i].commands.length != b[i].commands.length) return false;
        for (int j = 0; j < a[i].commands.length; j++) {
          if (!identical(a[i].commands[j], b[i].commands[j])) {
            if (a[i].commands[j].title != b[i].commands[j].title ||
                a[i].commands[j].runtimeType != b[i].commands[j].runtimeType) {
              return false;
            }
          }
        }
      }
    }
    return true;
  }

  void _doRegister() {
    if (!_routeActive) return;
    _register ??= CommandRegistry.of(context).register();
    _register!(_resolvedCommands);
  }

  void _onListenableChanged() {
    final newCommands = _resolveCommands();
    if (!_commandsEqual(_resolvedCommands, newCommands)) {
      setState(() {
        _resolvedCommands = newCommands;
        if (_register != null) {
          _doRegister();
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _resolvedCommands = _resolveCommands();
    widget.listenable?.addListener(_onListenableChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _doRegister();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute.of(context) subscribes via _ModalScopeStatus, so this fires
    // when route currentness changes — preventing command accumulation from
    // route pages kept alive by the router.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;

    if (isCurrent && !_routeActive) {
      _routeActive = true;
      _doRegister();
    } else if (!isCurrent && _routeActive) {
      _routeActive = false;
      _register?.call([]); // Clear commands but preserve position in _commands
    }
  }

  @override
  void didUpdateWidget(covariant CommandScope oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable?.removeListener(_onListenableChanged);
      widget.listenable?.addListener(_onListenableChanged);
    }

    final newCommands = _resolveCommands();
    if (!_commandsEqual(_resolvedCommands, newCommands)) {
      _resolvedCommands = newCommands;
      if (_register != null) {
        _doRegister();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final commandBindings = _resolvedCommands
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

    final groupBindings = _resolvedCommands
        .fold<Map<ShortcutActivator, VoidCallback>>(
          {},
          (bindings, group) => group.shortcut == null
              ? bindings
              : {
                  ...bindings,
                  group.shortcut!: () {
                    try {
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
        platformSingleActivator(LogicalKeyboardKey.keyK): () =>
            Commands(
              prompt: 'Run a command',
              groups: CommandRegistry.of(context).commands,
            ).show(context),
        ...commandBindings,
        ...groupBindings,
      },
      child: widget.child,
    );
  }

  @override
  void dispose() {
    widget.listenable?.removeListener(_onListenableChanged);
    _register?.call(null);
    super.dispose();
  }
}
