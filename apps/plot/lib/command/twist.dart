import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
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

class ManageTwists extends ShowCommands {
  ManageTwists(Priority priority)
    : super(
        title: 'Manage Twists',
        icon: PlotIcon.twist,
        commands: (context) => _getTwistCommands(priority),
      );

  static Future<Commands> _getTwistCommands(Priority priority) async {
    final results = await Future.wait([
      TwistApi.getTwistsForPriority(priority),
      TwistApi.getAllTwists(priority),
    ]);

    final priorityTwists = results[0] as List<PriorityTwist>;
    final allTwists = results[1] as List<Twist>;

    final editCommands = priorityTwists
        .map((twist) => EditTwistCommand(priority, twist))
        .toList();

    final viewCommands = allTwists
        .map(
          (twist) =>
              ViewTwistDetailsCommand(priority, twist, isInstalled: false),
        )
        .toList();

    return Commands(
      groups: [
        StaticCommandGroup(title: 'Active Twists', commands: editCommands),
        StaticCommandGroup(title: 'Available Twists', commands: viewCommands),
      ],
    );
  }
}

class ViewTwistDetailsCommand extends ShowCommands {
  ViewTwistDetailsCommand(
    this.priority,
    this.twist, {
    required this.isInstalled,
    this.priorityTwist,
  }) : super(
         title: _formatTwistName(twist.name, twist.environment),
         icon: PlotIcon.twist,
         commands: (context) =>
             _getDetailCommands(priority, twist, isInstalled, priorityTwist),
       );

  final Priority priority;
  final Twist twist;
  final bool isInstalled;
  final PriorityTwist? priorityTwist;

  static Future<Commands> _getDetailCommands(
    Priority priority,
    Twist twist,
    bool isInstalled,
    PriorityTwist? priorityTwist,
  ) async {
    final commands = <Command>[];

    if (isInstalled && priorityTwist != null) {
      commands.add(RemoveTwist(priorityTwist));
    } else {
      commands.add(AddTwist(priority, twist));
    }

    return Commands(
      groups: [
        StaticCommandGroup(
          infoBuilder: (context) => TwistDetails(twist: twist),
          commands: commands,
        ),
      ],
    );
  }
}

class EditTwistCommand extends ShowCommands {
  EditTwistCommand(this.priority, this.priorityTwist)
    : super(
        title: _formatTwistName(
          priorityTwist.name,
          priorityTwist.twistEnvironment,
        ),
        icon: PlotIcon.settings,
        commands: (context) => _getTwistCommands(priority, priorityTwist),
      );

  final Priority priority;
  final PriorityTwist priorityTwist;

  static Future<Commands> _getTwistCommands(
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

      return Commands(
        groups: [
          StaticCommandGroup(
            infoBuilder: (context) => TwistDetails(twist: matchingTwist),
            commands: [RemoveTwist(priorityTwist)],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading twist details', e, t);
      // Fallback to simple commands without details
      return Commands(
        groups: [
          StaticCommandGroup(
            title: 'Twist Commands',
            commands: [RemoveTwist(priorityTwist)],
          ),
        ],
      );
    }
  }
}

class AddTwist extends Command {
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
  Future<CommandReturn> run(BuildContext context) async {
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

      return CommandMessage(
        'Twist "${_formatTwistName(twist.name, twist.environment)}" added successfully',
      );
    } catch (e, t) {
      log.warning('Failed to add twist', e, t);
      return CommandMessage(
        'Failed to add twist: ${e.toString()}',
        isError: true,
      );
    }
  }
}

class RemoveTwist extends Command {
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
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.removeTwist(twist.id);

      // Reload twists in PriorityBloc
      if (context.mounted) {
        await context.read<PriorityBloc>().reloadTwists();
      }

      return CommandMessage(
        'Twist "${_formatTwistName(twist.name, twist.twistEnvironment)}" removed successfully',
      );
    } catch (e) {
      return CommandMessage(
        'Failed to remove twist: ${e.toString()}',
        isError: true,
      );
    }
  }
}
