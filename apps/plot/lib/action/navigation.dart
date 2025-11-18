import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/analytics.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/state/layout.dart';
import 'action.dart';

class CloseModalAction extends Action {
  CloseModalAction()
    : super(
        title: 'Close',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: PlotIcon.close,
      );

  @override
  Future<ActionReturn> run(BuildContext context) async {
    await context.router.maybePop();
    return const ActionDone();
  }
}

class ToggleLeftSidebarAction extends Action {
  ToggleLeftSidebarAction({required this.isVisible})
    : super(
        title: isVisible ? 'Close Left Sidebar' : 'Open Left Sidebar',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: isVisible ? PlotIcon.sidebarClose : PlotIcon.sidebarOpen,
      );

  final bool isVisible;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    final layoutBloc = context.read<LayoutBloc>();
    final currentState = layoutBloc.state;
    layoutBloc.setLeftPanelVisible(!currentState.leftPanelVisible);
    return const ActionDone();
  }
}

class ToggleMiddleSidebarAction extends Action {
  ToggleMiddleSidebarAction({required this.isVisible})
    : super(
        title: isVisible ? 'Close Middle Sidebar' : 'Open Middle Sidebar',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: isVisible ? PlotIcon.sidebarClose : PlotIcon.sidebarOpen,
      );

  final bool isVisible;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    final layoutBloc = context.read<LayoutBloc>();
    final currentState = layoutBloc.state;
    layoutBloc.setMiddlePanelVisible(!currentState.middlePanelVisible);
    return const ActionDone();
  }
}

class ToggleSearchAction extends Action {
  ToggleSearchAction({required this.searchExpanded, required this.onToggle})
    : super(
        title: searchExpanded ? 'Close Search' : 'Search',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: searchExpanded ? PlotIcon.close : PlotIcon.search,
        shortcut: const SingleActivator(LogicalKeyboardKey.slash, meta: true),
      );

  final bool searchExpanded;
  final VoidCallback onToggle;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    onToggle();
    return const ActionDone();
  }
}
