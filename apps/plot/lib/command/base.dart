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
  const CommandDone({this.message, this.createdId});

  /// Optional success message to show as a toast
  final String? message;

  /// Optional id of an entity the command just created (e.g. a contact or
  /// group), as a canonical UUID string. Lets a caller react to the new id —
  /// e.g. bump it in the new-thread People MRU — without a separate lookup.
  /// A plain string (not `Uuid`) keeps store types out of `command/base.dart`.
  final String? createdId;
}

// The user aborted the command (e.g. by pressing Escape)
class CommandSkipped extends CommandReturn {
  const CommandSkipped();
}

// The user consented to a connection add-on charge (web/Stripe path) without
// any upfront charge. The caller should proceed to enable the connection with
// `consentAddon: true`; the server charges on enable (or returns needs_card to
// capture a card first). Returned by the connection-capacity consent gate
// instead of charging upfront. The App Store path does NOT use this — it
// completes a StoreKit purchase and returns [CommandDone].
class CommandAddonConsented extends CommandReturn {
  const CommandAddonConsented();
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
    if (!context.mounted) return;
    try {
      if (replace) {
        await context.router.root.replace(route);
      } else {
        await context.router.root.navigate(route);
      }
    } on TypeError {
      // AutoRouter.of(context) uses `!` on null when no router ancestor exists
      // (e.g. command triggered from a modal/overlay outside the router tree).
      // In release mode this throws _TypeError instead of the debug FlutterError.
      log.warning('Router not available for navigation to $route');
    }
  }
}

abstract class Command {
  const Command({
    required this.title,
    required this.eventObject,
    required this.eventAction,
    this.subtitle,
    this.searchTerms,
    this.description,
    this.icon,
    this.hoverIcon,
    this.shortcut,
    this.on,
  });

  /// Set by keyboard shortcut handlers before running a command.
  /// Read and cleared by [BuildContextCommandExtension.run] to force filter visibility.
  static bool triggeredByShortcut = false;

  final String title;
  final EventObject eventObject;
  final EventAction eventAction;
  final String? subtitle;

  /// Extra text matched by [CommandGroup.filter] but never displayed. Lets a
  /// command be found by terms outside its visible label — e.g. a focus
  /// command includes its role name so "marlow" surfaces every "AFC Marlow ›"
  /// focus. Matched at a lower rank than [title]/[subtitle] so visible-label
  /// matches sort first.
  final String? searchTerms;

  /// Longer description displayed below the title in command modals.
  final String? description;
  final IconData? icon;
  final IconData? hoverIcon;
  final ShortcutActivator? shortcut;
  // state for toggle actions
  final bool? on;

  /// Whether this command has unread content (e.g. unread priority).
  bool get unread => false;

  /// Command-specific properties attached to this command's PostHog action
  /// event (merged into [buildActionProperties] via `extra`). Override to
  /// describe *what kind* of action this was — e.g. a created note reports
  /// `is_todo` / `attachment_count` / `recipient_scope` — so toggles that feed
  /// the action don't each need their own event. Null values are dropped.
  /// Read once, after the command runs, by [BuildContextCommandExtension.run].
  Map<String, Object?> get eventProperties => const {};

  /// Override to provide custom enabled logic based on context.
  /// Returns true by default (command is enabled).
  bool enabled(BuildContext context) => true;

  /// Optional alternate command invoked on long-press. Null = no long-press action.
  Command? get longPressCommand => null;

  /// Optional secondary axis exposed by this command. When non-null, the
  /// hosting modal renders [CommandSecondaryAxis.buildBadge] as the row's
  /// trailing widget (tap = cycle forward) and intercepts left/right arrow
  /// keys while the row is highlighted to call [CommandSecondaryAxis.cycle].
  /// Cycling does NOT run the command — it's a separate axis of state on
  /// the same row. Used today for contact roles (To / CC / BCC) on the
  /// thread share picker.
  CommandSecondaryAxis? get secondaryAxis => null;

  Future<CommandReturn> run(BuildContext context);

  /// Override to provide a custom icon widget (e.g., Avatar) instead of IconData.
  /// This is specifically for icon-only display and takes precedence over [icon].
  ///
  /// The [hoverIcon] parameter indicates whether the button is being hovered.
  /// Defaults to false (not hovering).
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) => null;

  /// Override to provide custom body content for the command in modals/lists.
  Widget? buildBody(BuildContext context) => null;

  /// Override to provide a custom description widget rendered below the title
  /// in command modals. Takes precedence over the static [description] field.
  Widget? buildDescription(BuildContext context) => null;
}

/// Secondary axis exposed by a [Command] for in-row cycling (e.g. role
/// changes on a thread contact). Pure data — the modal layer renders the
/// badge (so it can wire the tap into its refresh pipeline) and invokes
/// [cycle] on tap or arrow key.
abstract class CommandSecondaryAxis {
  const CommandSecondaryAxis();

  /// Short label shown in the row's trailing slot (e.g. "TO").
  String get badgeLabel;

  /// Cycle the axis by [delta] (typically +1 forward, -1 backward, wraps).
  /// The returned [CommandReturn] is routed through the modal's
  /// command-result handler so [CommandRefresh] re-renders the list with
  /// the new value.
  Future<CommandReturn> cycle(BuildContext context, int delta);
}

class CommandWrapper extends Command {
  final Command command;
  final Future<CommandReturn> Function(Command command, BuildContext context)?
  _run;
  final bool _iconOverridden;

  CommandWrapper(
    this.command, {
    Future<CommandReturn> Function(Command command, BuildContext context)? run,
    Value<IconData?> icon = const Value<IconData?>.absent(),
    Value<IconData?> hoverIcon = const Value<IconData?>.absent(),
    String? title,
    Value<String?> subtitle = const Value<String?>.absent(),
    // ignore: prefer_initializing_formals
  }) : _run = run,
       _iconOverridden = icon.present,
       super(
         title: title ?? command.title,
         eventObject: command.eventObject,
         eventAction: command.eventAction,
         subtitle: subtitle.or(command.subtitle),
         description: command.description,
         icon: icon.or(command.icon),
         hoverIcon: hoverIcon.or(command.hoverIcon),
         shortcut: command.shortcut,
         on: command.on,
       );

  @override
  bool get unread => command.unread;

  @override
  Map<String, Object?> get eventProperties => command.eventProperties;

  @override
  bool enabled(BuildContext context) => command.enabled(context);

  @override
  Command? get longPressCommand => command.longPressCommand;

  @override
  CommandSecondaryAxis? get secondaryAxis => command.secondaryAxis;

  @override
  Future<CommandReturn> run(BuildContext context) {
    if (_run != null) {
      return _run(command, context);
    }
    return command.run(context);
  }

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      _iconOverridden ? null : command.buildIcon(context, hoverIcon: hoverIcon);

  @override
  Widget? buildBody(BuildContext context) => command.buildBody(context);

  @override
  Widget? buildDescription(BuildContext context) =>
      command.buildDescription(context);
}

/// A command for showing a set of commands.
///
/// Provide either [commands] (static) or [commandsBuilder] (async/dynamic),
/// not both.
class ShowCommands extends Command {
  ShowCommands({
    required super.title,
    super.description,
    super.icon,
    super.hoverIcon,
    super.shortcut,
    this.commands,
    this.commandsBuilder,
    this.showFilter,
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

  /// Controls filter visibility. `null` = auto (item-count heuristic),
  /// `true` = always show, `false` = never show.
  final bool? showFilter;

  /// Set by [BuildContextCommandExtension.run] when the command was
  /// triggered via a keyboard shortcut.
  bool _fromShortcut = false;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final commandsInstance = commands ?? await commandsBuilder!(context);
      if (!context.mounted) {
        log.info(
          'Context no longer mounted, skipping CommandModal for "$title"',
        );
        return const CommandSkipped();
      }
      return await CommandModal(
        commandsInstance,
        rootContext: context,
        showFilter: showFilter ?? (_fromShortcut ? true : null),
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
    // Capture and clear the keyboard shortcut flag
    final fromShortcut = Command.triggeredByShortcut;
    Command.triggeredByShortcut = false;
    if (command is ShowCommands && fromShortcut) {
      command._fromShortcut = true;
    }

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

      if (result is CommandDone && result.message != null) {
        showToast(message: result.message!);
      } else if (result is CommandMessage) {
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
          extra: command.eventProperties,
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
  CommandGroup({
    this.title,
    this.subtitle,
    this.infoBuilder,
    this.shortcut,
    this.onActivate,
  });

  final String? title;
  final String? subtitle; // count
  final Widget? Function(BuildContext, String? search)? infoBuilder;
  final ShortcutActivator? shortcut;

  /// Called when an info-only group row is activated (Enter key or tap).
  final void Function(BuildContext)? onActivate;

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
        .where((command) =>
            match(command.title) ||
            match(command.subtitle) ||
            match(command.searchTerms))
        .toList()
      // Visible-label matches (title 3, subtitle 2) sort above commands matched
      // only by their hidden [Command.searchTerms] (1).
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
    super.onActivate,
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
    this.prompt,
    required this.groups,
    this.secondaryCommand,
    this.emptyMessage,
    this.clearSearchOnRun = false,
  });

  final String? prompt;
  final List<CommandGroup> groups;
  final Command? Function(String promptValue)? secondaryCommand;
  final String? emptyMessage;

  /// When true, the host modal clears its search field each time a command is
  /// run (and the list refreshes). Used by multi-select pickers (e.g. the share
  /// picker) so that after toggling a filtered match, the filter resets and all
  /// current selections become visible again.
  final bool clearSearchOnRun;

  Future<CommandReturn> show(BuildContext context, {bool? showFilter}) async {
    try {
      return await CommandModal(
        this,
        rootContext: context,
        showFilter: showFilter,
      ).run(context);
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

      // Include group if it has matching commands or an infoBuilder
      if (matchingCommands.isNotEmpty || group.infoBuilder != null) {
        filteredCommandGroups.add(
          StaticCommandGroup(
            title: group.title,
            subtitle: group.subtitle,
            infoBuilder: group.infoBuilder,
            shortcut: group.shortcut,
            onActivate: group.onActivate,
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
/// Propagates route-active state to descendant [CommandScope]s.
///
/// When a [CommandScope] detects its [ModalRoute] is no longer current (e.g. a
/// new route was pushed on top), it provides `active: false` to descendants.
/// Nested [CommandScope]s subscribe to this via [of] and clear their commands
/// even though their own [ModalRoute] is still current within their local
/// navigator.
class _CommandScopeActive extends InheritedWidget {
  const _CommandScopeActive({required this.active, required super.child});
  final bool active;

  static bool of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_CommandScopeActive>()
            ?.active ??
        true;
  }

  @override
  bool updateShouldNotify(_CommandScopeActive oldWidget) =>
      active != oldWidget.active;
}

/// When using [commandsBuilder], optionally provide a [listenable] to trigger rebuilds.
///
/// Route-aware: automatically unregisters when the enclosing [ModalRoute] is no
/// longer current and re-registers when it becomes current again. This prevents
/// command accumulation when route pages are kept alive by the router.
///
/// Also propagates active state to descendant [CommandScope]s via
/// [_CommandScopeActive], so nested scopes (e.g. ThreadRoute inside
/// PriorityRoute) are deactivated when an ancestor route is pushed behind.
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

  void _doRegister() {
    if (!_routeActive) return;
    _register ??= CommandRegistry.of(context).register();
    _register!(_resolvedCommands);
  }

  void _onListenableChanged() {
    // Always re-resolve and re-register: commandsBuilder closures commonly
    // capture state (e.g. EditNote(note)) that title/runtimeType comparison
    // can't detect, so any cheap equality check would silently keep stale
    // bindings — Cmd+K → Edit then runs against the previously focused note
    // instead of the currently focused one.
    setState(() {
      _resolvedCommands = _resolveCommands();
      if (_register != null) {
        _doRegister();
      }
    });
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
    //
    // _CommandScopeActive.of(context) catches the nested-navigator case: when
    // a route is pushed at a *parent* navigator level, the child's ModalRoute
    // stays current but the ancestor CommandScope propagates active: false.
    final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final ancestorActive = _CommandScopeActive.of(context);
    final shouldBeActive = routeCurrent && ancestorActive;

    if (shouldBeActive && !_routeActive) {
      _routeActive = true;
      _doRegister();
    } else if (!shouldBeActive && _routeActive) {
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

    _resolvedCommands = _resolveCommands();
    if (_register != null) {
      _doRegister();
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
                      Command.triggeredByShortcut = true;
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
                        prompt: group.title,
                        groups: [group],
                      ).show(context, showFilter: true);
                    } catch (e, t) {
                      log.warning('Error opening command group', e, t);
                      rethrow;
                    }
                  },
                },
        );

    return _CommandScopeActive(
      active: _routeActive,
      child: CallbackShortcuts(
        bindings: {
          platformSingleActivator(LogicalKeyboardKey.keyK): () => Commands(
            groups: CommandRegistry.of(context).commands,
          ).show(context, showFilter: true),
          ...commandBindings,
          ...groupBindings,
        },
        child: widget.child,
      ),
    );
  }

  @override
  void dispose() {
    widget.listenable?.removeListener(_onListenableChanged);
    _register?.call(null);
    super.dispose();
  }
}
