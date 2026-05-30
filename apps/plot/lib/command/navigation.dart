import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/util/shortcut.dart';
import 'command.dart';

class PageBackCommand extends Command {
  PageBackCommand()
    : super(
        title: 'Page back',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: PlotIcon.back,
        shortcut: platformSingleActivator(LogicalKeyboardKey.bracketLeft),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Walk the URL navigation history, mirroring the browser back
    // button's behaviour. Bottom-nav taps and in-tab priority switches
    // use `markUrlStateForReplace` so URL history only contains the
    // user's meaningful navigation steps, which makes this back walk
    // do the right thing — go to the previous tab or the originating
    // priority list — without ever surfacing a phantom intermediate
    // priority. Mobile system back gestures take a different path
    // (PopScope on [PriorityOnlyPage]) but end up at the same destination
    // because URL history and the widget stack are kept aligned.
    context.router.back();
    return const CommandDone();
  }
}

class CloseModalCommand extends Command {
  CloseModalCommand()
    : super(
        title: 'Close',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: PlotIcon.close,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await context.router.maybePop();
    return const CommandDone();
  }
}

class ToggleLeftSidebarCommand extends Command {
  ToggleLeftSidebarCommand({required this.isVisible})
    : super(
        title: isVisible
            ? 'Hide agenda and focuses'
            : 'Open sidebar',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: isVisible ? PlotIcon.sidebarClose : PlotIcon.sidebarOpen,
      );

  final bool isVisible;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final layoutBloc = context.read<LayoutBloc>();
    final currentState = layoutBloc.state;
    layoutBloc.setLeftPanelVisible(!currentState.leftPanelVisible);
    return const CommandDone();
  }
}

class ToggleMiddleSidebarCommand extends Command {
  ToggleMiddleSidebarCommand({required this.isVisible})
    : super(
        title: isVisible ? 'Close threads' : 'Open threads',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: isVisible ? PlotIcon.sidebarClose : PlotIcon.sidebarOpen,
      );

  final bool isVisible;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final layoutBloc = context.read<LayoutBloc>();
    final currentState = layoutBloc.state;
    layoutBloc.setMiddlePanelVisible(!currentState.middlePanelVisible);
    return const CommandDone();
  }
}

class CyclePanelsCommand extends Command {
  CyclePanelsCommand({required LayoutState layoutState})
    : super(
        title: _title(layoutState),
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: _icon(layoutState),
      );

  /// Label for use in platform menu bars.
  static String menuLabel(LayoutState layoutState) => _title(layoutState);

  static String _title(LayoutState layoutState) {
    // Multi-panel mode is always 2 (no left sidebar) or 3 (with left
    // sidebar) panels — the middle is always visible. The only thing to
    // cycle is the left sidebar.
    return layoutState.leftPanelVisible
        ? 'Hide agenda and focuses'
        : 'Open sidebar';
  }

  static IconData _icon(LayoutState layoutState) {
    return layoutState.leftPanelVisible
        ? PlotIcon.sidebarClose
        : PlotIcon.sidebarOpen;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final layoutBloc = context.read<LayoutBloc>();
    final state = layoutBloc.state;
    layoutBloc.setLeftPanelVisible(!state.leftPanelVisible);
    return const CommandDone();
  }
}

/// Menu bar version of [CyclePanelsCommand] that uses [LayoutBloc.instance]
/// directly, since the menu bar runs outside the [LayoutBloc] provider scope.
class ToggleSidebarCommand extends Command {
  ToggleSidebarCommand()
    : super(
        title: 'Toggle sidebar',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: PlotIcon.sidebarOpen,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final layoutBloc = LayoutBloc.instance;
    if (layoutBloc == null) return const CommandDone();
    layoutBloc.setLeftPanelVisible(!layoutBloc.state.leftPanelVisible);
    return const CommandDone();
  }
}

class ToggleSearchCommand extends Command {
  ToggleSearchCommand({required this.searchExpanded, required this.onToggle})
    : super(
        title: searchExpanded ? 'Close search' : 'Search',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: searchExpanded ? PlotIcon.close : PlotIcon.search,
        shortcut: platformSingleActivator(LogicalKeyboardKey.slash),
      );

  final bool searchExpanded;
  final VoidCallback onToggle;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    onToggle();
    return const CommandDone();
  }
}

class BackToPrioritiesTabCommand extends Command {
  BackToPrioritiesTabCommand()
    : super(
        title: 'Focuses',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: PlotIcon.back,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    AutoTabsRouter.of(context).setActiveIndex(0);
    return const CommandDone();
  }
}
