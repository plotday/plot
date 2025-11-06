import 'package:flutter/services.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/util/value.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/analytics/analytics.dart';
import 'provider.dart';
import 'logging.dart';

sealed class ActionReturn {
  const ActionReturn();
}

// Action completed successfully
class ActionDone extends ActionReturn {
  const ActionDone();
}

// The user aborted the action (e.g. by pressing Escape)
class ActionSkipped extends ActionReturn {
  const ActionSkipped();
}

// Status message from running the action
class ActionMessage extends ActionReturn {
  const ActionMessage(this.message, {this.isError = false});
  final String message;
  final bool isError;
}

// Action is triggering navigation
class ActionRoute extends ActionReturn {
  const ActionRoute(this.route, {this.replace = false});
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

abstract class Action {
  const Action({
    required this.title,
    required this.eventObject,
    required this.eventAction,
    this.subtitle,
    this.description,
    this.icon,
    this.shortcut,
    this.on,
  });

  final String title;
  final EventObject eventObject;
  final EventAction eventAction;
  final String? subtitle;
  final String? description;
  final IconData? icon;
  final ShortcutActivator? shortcut;
  // state for toggle actions
  final bool? on;

  Future<ActionReturn> run(BuildContext context);

  Widget? buildBody(BuildContext context) => null;
}

class ActionWrapper extends Action {
  final Action action;
  final Future<ActionReturn> Function(Action action, BuildContext context)?
  _run;

  ActionWrapper(
    this.action, {
    Future<ActionReturn> Function(Action action, BuildContext context)? run,
    Value<IconData?> icon = const Value<IconData?>.absent(),
  }) : _run = run,
       super(
         title: action.title,
         eventObject: action.eventObject,
         eventAction: action.eventAction,
         subtitle: action.subtitle,
         description: action.description,
         icon: icon.or(action.icon),
         shortcut: action.shortcut,
       );

  @override
  Future<ActionReturn> run(BuildContext context) {
    if (_run != null) {
      return _run(action, context);
    }
    return action.run(context);
  }

  @override
  Widget? buildBody(BuildContext context) => action.buildBody(context);
}

/// A action for showing a set of actions
class ShowActions extends Action {
  ShowActions({
    required super.title,
    super.description,
    super.icon,
    super.shortcut,
    required this.actions,
    EventObject? eventObject,
    EventAction? eventAction,
  }) : super(
         eventObject: eventObject ?? EventObject.actionBar,
         eventAction: eventAction ?? EventAction.opened,
       );

  final Future<Actions> Function(BuildContext context) actions;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    try {
      final actionsInstance = await actions(context);
      if (!context.mounted) return const ActionSkipped();
      return await ActionBar(actionsInstance, rootContext: context).run(context);
    } on Error catch (e, t) {
      log.warning('Action "$title" failed', e, t);
      rethrow;
    }
  }
}

/// A action for showing a page widget in a dialog
class ShowPage extends Action {
  ShowPage({
    required super.title,
    super.description,
    super.icon,
    super.shortcut,
    required this.builder,
    EventObject? eventObject,
    EventAction? eventAction,
  }) : super(
         eventObject: eventObject ?? EventObject.dialog,
         eventAction: eventAction ?? EventAction.opened,
       );

  final Widget Function(BuildContext context) builder;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    final actionReturn = await Dialog(
      builder: builder,
    ).show<ActionReturn>(context);
    return actionReturn.present ? actionReturn.value : const ActionSkipped();
  }
}

extension BuildContextActionExtension on BuildContext {
  Future<void> run(Action action) async {
    // Start timing the action execution
    final startTime = DateTime.now();
    final actionType = action.runtimeType.toString();

    ActionReturn? result;
    String? errorType;
    String? errorMessage;
    bool success = true;

    try {
      result = await action.run(this);

      // Determine success based on ActionReturn type
      if (result is ActionMessage && result.isError) {
        success = false;
        errorMessage = result.message;
      }

      // TODO show toast for ActionMessage
      if (result is ActionRoute) {
        await result.go(this);
      }
    } catch (e, stackTrace) {
      success = false;
      errorType = e.runtimeType.toString();
      errorMessage = e.toString();

      // Track error event using explicit enum values
      await Analytics.instance.trackError(
        action.eventObject.value,
        errorType: errorType,
        errorMessage: errorMessage,
        stackTrace: extractStackTrace(stackTrace),
        context: 'action_execution',
      );

      rethrow;
    } finally {
      // Calculate duration
      final durationMs = DateTime.now().difference(startTime).inMilliseconds;

      // Track action execution using explicit enum values
      await Analytics.instance.trackAction(
        action.eventObject,
        action.eventAction,
        buildActionProperties(
          actionType: actionType,
          success: success,
          durationMs: durationMs,
          errorType: errorType,
          errorMessage: errorMessage,
        ),
      );

      // Track performance issue if action took too long
      const performanceThresholdMs = 2000;
      if (durationMs > performanceThresholdMs) {
        await Analytics.instance.trackPerformance(
          object: EventObject.action,
          durationMs: durationMs,
          thresholdMs: performanceThresholdMs,
          operationType: actionType,
        );
      }
    }
  }
}

abstract class ActionGroup {
  ActionGroup({this.title, this.subtitle, this.infoBuilder});

  final String? title;
  final String? subtitle; // count
  final Widget Function(BuildContext)? infoBuilder;

  Future<List<Action>> list({String? search});

  static List<Action> filter(List<Action> actions, String? search) {
    if (search == null || search.isEmpty) {
      return actions;
    }

    String searchLower = search.toLowerCase();
    bool match(String? field) {
      if (field == null) return false;
      return RegExp(
        '\\b${RegExp.escape(searchLower)}',
      ).hasMatch(field.toLowerCase());
    }

    return actions
        .where(
          (action) =>
              match(action.title) ||
              match(action.subtitle) ||
              match(action.description),
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

class StaticActionGroup extends ActionGroup {
  StaticActionGroup({
    super.title,
    super.subtitle,
    super.infoBuilder,
    required this.actions,
  });

  final List<Action> actions;

  @override
  Future<List<Action>> list({String? search}) async {
    return ActionGroup.filter(actions, search);
  }
}

class Actions {
  const Actions({String? prompt, required this.groups, this.secondaryAction})
    : prompt = prompt ?? 'Run a action';

  final String prompt;
  final List<ActionGroup> groups;
  final Action? Function(String promptValue)? secondaryAction;

  Future<ActionReturn> show(BuildContext context) async {
    try {
      return await ActionBar(
        this,
        secondaryAction: secondaryAction,
        rootContext: context,
      ).run(context);
    } on Error catch (e, t) {
      log.warning('Error running action bar', e, t);
      rethrow;
    }
  }

  Future<List<StaticActionGroup>> list({String? search}) async {
    // Filter the actions based on the search query
    List<StaticActionGroup> filteredActionGroups = [];
    for (var group in groups) {
      // Filter actions within the group
      List<Action> matchingActions = await group.list(search: search);

      // If any actions match, include the group with matching actions
      if (matchingActions.isNotEmpty) {
        filteredActionGroups.add(
          StaticActionGroup(
            title: group.title,
            subtitle: group.subtitle,
            infoBuilder: group.infoBuilder,
            actions: matchingActions,
          ),
        );
      }
    }
    return filteredActionGroups;
  }
}

/// Activate new actions in the given widget scope. This adds a new scope for the ActionBar,
/// along with activating shortcuts for the actions.
class ActionScope extends StatefulWidget {
  const ActionScope({required this.actions, required this.child, super.key});

  final List<StaticActionGroup> actions;
  final Widget child;

  @override
  ActionScopeState createState() => ActionScopeState();
}

class ActionScopeState extends State<ActionScope> {
  RegisterActionGroups? register;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: widget.actions.expand((group) => group.actions).fold(
        <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              Actions(
                prompt: 'Run a action',
                groups: ActionRegistry.of(context).actions,
              ).show(context),
        },
        (bindings, action) => action.shortcut == null
            ? bindings
            : {
                ...bindings,
                action.shortcut!: () {
                  try {
                    context.run(action);
                  } catch (e, t) {
                    log.warning('Error running action', e, t);
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
  void didUpdateWidget(covariant ActionScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  void _register() {
    if (register == null) {
      ActionRegistry registry = ActionRegistry.of(context);
      register = registry.register();
    }
    register!(widget.actions);
  }

  @override
  void dispose() {
    register?.call(null);
    super.dispose();
  }
}
