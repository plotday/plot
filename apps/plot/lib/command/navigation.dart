import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/state/layout.dart';
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
        title: isVisible ? 'Close Activities' : 'Open Activities',
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

class ToggleSearchCommand extends Command {
  ToggleSearchCommand({required this.searchExpanded, required this.onToggle})
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
  Future<CommandReturn> run(BuildContext context) async {
    onToggle();
    return const CommandDone();
  }
}
