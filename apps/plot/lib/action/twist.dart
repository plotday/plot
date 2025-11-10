import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'action.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/store/store.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/twist_details.dart';
import 'logging.dart';

/// Formats twist name with environment label if not public
String _formatTwistName(String name, String environment) {
  if (environment == 'public') {
    return name;
  }
  final envLabel = environment[0].toUpperCase() + environment.substring(1);
  return '$name ($envLabel)';
}

class ManageTwists extends ShowActions {
  ManageTwists(Priority priority)
    : super(
        title: 'Manage Twists',
        icon: PlotIcon.twist,
        actions: (context) => _getTwistActions(priority),
      );

  static Future<Actions> _getTwistActions(Priority priority) async {
    final results = await Future.wait([
      TwistApi.getTwistsForPriority(priority),
      TwistApi.getAllTwists(priority),
    ]);

    final priorityTwists = results[0] as List<PriorityTwist>;
    final allTwists = results[1] as List<Twist>;

    final editActions = priorityTwists
        .map((twist) => EditTwistAction(priority, twist))
        .toList();

    final viewActions = allTwists
        .map(
          (twist) =>
              ViewTwistDetailsAction(priority, twist, isInstalled: false),
        )
        .toList();

    return Actions(
      groups: [
        StaticActionGroup(title: 'Active Twists', actions: editActions),
        StaticActionGroup(title: 'Available Twists', actions: viewActions),
      ],
    );
  }
}

class ViewTwistDetailsAction extends ShowActions {
  ViewTwistDetailsAction(
    this.priority,
    this.twist, {
    required this.isInstalled,
    this.priorityTwist,
  }) : super(
         title: _formatTwistName(twist.name, twist.environment),
         icon: PlotIcon.twist,
         actions: (context) =>
             _getDetailActions(priority, twist, isInstalled, priorityTwist),
       );

  final Priority priority;
  final Twist twist;
  final bool isInstalled;
  final PriorityTwist? priorityTwist;

  static Future<Actions> _getDetailActions(
    Priority priority,
    Twist twist,
    bool isInstalled,
    PriorityTwist? priorityTwist,
  ) async {
    final actions = <Action>[];

    if (isInstalled && priorityTwist != null) {
      actions.add(RemoveTwist(priorityTwist));
    } else {
      actions.add(AddTwist(priority, twist));
    }

    return Actions(
      groups: [
        StaticActionGroup(
          infoBuilder: (context) => TwistDetails(twist: twist),
          actions: actions,
        ),
      ],
    );
  }
}

class EditTwistAction extends ShowActions {
  EditTwistAction(this.priority, this.priorityTwist)
    : super(
        title: _formatTwistName(
          priorityTwist.name,
          priorityTwist.twistEnvironment,
        ),
        icon: PlotIcon.settings,
        actions: (context) => _getTwistActions(priority, priorityTwist),
      );

  final Priority priority;
  final PriorityTwist priorityTwist;

  static Future<Actions> _getTwistActions(
    Priority priority,
    PriorityTwist priorityTwist,
  ) async {
    // Fetch the full Twist data to show details
    try {
      // Fetch all twists to find the matching one
      final allTwists = await TwistApi.getAllTwists(priority);
      final matchingTwist = allTwists.firstWhere(
        (a) =>
            a.id == priorityTwist.twistId &&
            a.environment == priorityTwist.twistEnvironment,
        orElse: () => throw Exception('Twist not found'),
      );

      return Actions(
        groups: [
          StaticActionGroup(
            infoBuilder: (context) => TwistDetails(twist: matchingTwist),
            actions: [RemoveTwist(priorityTwist)],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading twist details', e, t);
      // Fallback to simple actions without details
      return Actions(
        groups: [
          StaticActionGroup(
            title: 'Twist Actions',
            actions: [RemoveTwist(priorityTwist)],
          ),
        ],
      );
    }
  }
}

class AddTwist extends Action {
  AddTwist(this.priority, this.twist)
    : super(
        title: 'Add ${_formatTwistName(twist.name, twist.environment)}',
        subtitle: twist.description ?? 'Add this twist to priority',
        eventObject: EventObject.twist,
        eventAction: EventAction.added,
        icon: PlotIcon.twist,
      );

  final Priority priority;
  final Twist twist;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    try {
      await TwistApi.addTwist(
        priorityId: priority.id.toString(),
        twistId: twist.id,
        twistEnvironment: twist.environment,
      );

      // Reload twists in PriorityBloc
      if (context.mounted) {
        await context.read<PriorityBloc>().reloadTwists();
      }

      return ActionMessage(
        'Twist "${_formatTwistName(twist.name, twist.environment)}" added successfully',
      );
    } catch (e, t) {
      log.warning('Failed to add twist', e, t);
      return ActionMessage(
        'Failed to add twist: ${e.toString()}',
        isError: true,
      );
    }
  }
}

class RemoveTwist extends Action {
  RemoveTwist(this.twist)
    : super(
        title: 'Remove Twist',
        subtitle:
            'Remove ${_formatTwistName(twist.name, twist.twistEnvironment)} from this priority',
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
        icon: FontAwesomeIcons.trash,
      );

  final PriorityTwist twist;

  @override
  Future<ActionReturn> run(BuildContext context) async {
    try {
      await TwistApi.removeTwist(twist.id);

      // Reload twists in PriorityBloc
      if (context.mounted) {
        await context.read<PriorityBloc>().reloadTwists();
      }

      return ActionMessage(
        'Twist "${_formatTwistName(twist.name, twist.twistEnvironment)}" removed successfully',
      );
    } catch (e) {
      return ActionMessage(
        'Failed to remove twist: ${e.toString()}',
        isError: true,
      );
    }
  }
}
