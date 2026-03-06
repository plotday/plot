import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/util/shortcut.dart';
import 'command.dart';

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
        title: isVisible ? 'Close Priorities' : 'Open Priorities',
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
        title: isVisible ? 'Close Threads' : 'Open Threads',
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
    if (layoutState.leftPanelVisible || layoutState.middlePanelVisible) {
      return 'Close Sidebar';
    }
    return 'Open Sidebar';
  }

  static IconData _icon(LayoutState layoutState) {
    if (layoutState.leftPanelVisible || layoutState.middlePanelVisible) {
      return PlotIcon.sidebarClose;
    }
    return PlotIcon.sidebarOpen;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final layoutBloc = context.read<LayoutBloc>();
    final state = layoutBloc.state;
    final visibleCount = 1 +
        (state.leftPanelVisible ? 1 : 0) +
        (state.middlePanelVisible ? 1 : 0);

    final canShowThree =
        layoutBloc.width >= LayoutState.threePanelMinWidth;

    if (canShowThree) {
      // 3-panel capable: 3 → 2 (hide left) → 1 (hide middle) → 3
      if (visibleCount >= 3) {
        layoutBloc.setPanelVisibility(left: false);
      } else if (visibleCount == 2) {
        layoutBloc.setPanelVisibility(middle: false);
      } else {
        layoutBloc.setPanelVisibility(left: true, middle: true);
      }
    } else {
      // 2-panel: toggle the active sidebar panel on/off
      if (state.middlePanelVisible) {
        // Middle+Right → Right-only
        layoutBloc.setPanelVisibility(middle: false);
      } else if (state.leftPanelVisible) {
        // Left+Right → Right-only
        layoutBloc.setPanelVisibility(left: false);
      } else {
        // Right-only → restore left (browsing default)
        layoutBloc.setPanelVisibility(left: true);
      }
    }
    return const CommandDone();
  }
}

/// Menu bar version of [CyclePanelsCommand] that uses [LayoutBloc.instance]
/// directly, since the menu bar runs outside the [LayoutBloc] provider scope.
class ToggleSidebarCommand extends Command {
  ToggleSidebarCommand()
    : super(
        title: 'Toggle Sidebar',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: PlotIcon.sidebarOpen,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final layoutBloc = LayoutBloc.instance;
    if (layoutBloc == null) return const CommandDone();

    final state = layoutBloc.state;
    final visibleCount = 1 +
        (state.leftPanelVisible ? 1 : 0) +
        (state.middlePanelVisible ? 1 : 0);

    final canShowThree =
        layoutBloc.width >= LayoutState.threePanelMinWidth;

    if (canShowThree) {
      if (visibleCount >= 3) {
        layoutBloc.setPanelVisibility(left: false);
      } else if (visibleCount == 2) {
        layoutBloc.setPanelVisibility(middle: false);
      } else {
        layoutBloc.setPanelVisibility(left: true, middle: true);
      }
    } else {
      // 2-panel: toggle the active sidebar panel on/off
      if (state.middlePanelVisible) {
        layoutBloc.setPanelVisibility(middle: false);
      } else if (state.leftPanelVisible) {
        layoutBloc.setPanelVisibility(left: false);
      } else {
        layoutBloc.setPanelVisibility(left: true);
      }
    }
    return const CommandDone();
  }
}

class ToggleSearchCommand extends Command {
  ToggleSearchCommand({required this.searchExpanded, required this.onToggle})
    : super(
        title: searchExpanded ? 'Close Search' : 'Search',
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
