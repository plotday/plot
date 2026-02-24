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
        title: isVisible ? 'Close Topics' : 'Open Topics',
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

  static String _title(LayoutState layoutState) {
    final visibleCount = 1 +
        (layoutState.leftPanelVisible ? 1 : 0) +
        (layoutState.middlePanelVisible ? 1 : 0);
    if (visibleCount > 1) return 'Close Sidebar';
    return 'Open Sidebar';
  }

  static IconData _icon(LayoutState layoutState) {
    final visibleCount = 1 +
        (layoutState.leftPanelVisible ? 1 : 0) +
        (layoutState.middlePanelVisible ? 1 : 0);
    if (visibleCount > 1) return PlotIcon.sidebarClose;
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
      // 2-panel capable: 2 → 1 (hide middle) → 2
      if (visibleCount >= 2) {
        layoutBloc.setPanelVisibility(left: false, middle: false);
      } else {
        layoutBloc.setPanelVisibility(left: true, middle: true);
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
