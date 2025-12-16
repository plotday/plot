import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/now.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/widget/widget.dart';
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
  ManageTwists([Priority? priority])
    : super(
        title: 'Manage Twists',
        icon: PlotIcon.twist,
        commands: (context) => _getTwistCommands(priority),
      );

  static Future<Commands> _getTwistCommands(Priority? priority) async {
    final defaultPriority = priority ?? await Priority.getDefault();
    final results = await Future.wait([
      priority != null
          ? PriorityTwist.get(priority: priority, includeAncestors: false)
          : PriorityTwist.get(),
      TwistApi.getAllTwists(defaultPriority),
    ]);
    final priorityTwists = results[0] as List<PriorityTwist>;
    final allTwists = results[1] as List<Twist>;

    final editCommands = priorityTwists
        .map((twist) => EditTwistCommand(twist, priority: priority))
        .toList();

    final addCommands = allTwists
        .map((twist) => AddTwistForm(twist, defaultPriority: priority))
        .toList();

    return Commands(
      groups: [
        StaticCommandGroup(title: 'Active Twists', commands: editCommands),
        StaticCommandGroup(title: 'Available Twists', commands: addCommands),
      ],
    );
  }
}

class EditTwistCommand extends ShowCommands {
  EditTwistCommand(this.priorityTwist, {Priority? priority})
    : _priority = priority,
      super(
        title: _formatTwistName(
          priorityTwist.name,
          priorityTwist.twistEnvironment,
        ),
        icon: PlotIcon.settings,
        commands: (context) => _getTwistCommands(priorityTwist, priority),
      );

  final PriorityTwist priorityTwist;
  final Priority? _priority;

  @override
  Widget buildBody(BuildContext context) {
    // Load priority to show path
    return FutureBuilder<Priority?>(
      future: _priority != null
          ? Future.value(_priority)
          : Priority.getOne(priorityTwist.priorityId),
      builder: (context, snapshot) {
        final priority = snapshot.data;
        if (priority == null) {
          return Text(
            _formatTwistName(
              priorityTwist.name,
              priorityTwist.twistEnvironment,
            ),
            style: context.theme.typography.base,
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _formatTwistName(
                priorityTwist.name,
                priorityTwist.twistEnvironment,
              ),
              style: context.theme.typography.base,
            ),
            if (priority.ancestorsLabel() != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      priority.ancestorsLabel()!,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                  Text(
                    Priority.separator,
                    style: context.theme.typography.sm.copyWith(
                      color: context.theme.colors.mutedForeground,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      priority.title,
                      overflow: TextOverflow.ellipsis,
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ] else
              Text(
                priority.title,
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
          ],
        );
      },
    );
  }

  static Future<Commands> _getTwistCommands(
    PriorityTwist priorityTwist,
    Priority? priority,
  ) async {
    // Fetch the full Twist data to show details
    try {
      // Load priority if not provided
      final loadedPriority =
          priority ?? await Priority.getOne(priorityTwist.priorityId);

      // Fetch all twists to find the matching one
      final allTwists = await TwistApi.getAllTwists(loadedPriority);
      final matchingTwist = allTwists.firstWhere(
        (a) =>
            a.id == priorityTwist.twistId.toString() &&
            a.environment == priorityTwist.twistEnvironment,
        orElse: () => throw Exception('Twist not found'),
      );

      return Commands(
        groups: [
          StaticCommandGroup(
            infoBuilder: (context) =>
                TwistDetails(twist: matchingTwist, priority: loadedPriority),
            commands: [
              ArchiveActivitiesCreatedByTwist(priorityTwist),
              RemoveTwist(priorityTwist),
            ],
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

class AddTwistForm extends ShowForm {
  AddTwistForm(this.twist, {Priority? defaultPriority})
    : super(
        title: 'Add ${_formatTwistName(twist.name, twist.environment)}',
        icon: PlotIcon.twist,
        form: (context) => _buildForm(context, twist, defaultPriority),
      );

  final Twist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    Twist twist,
    Priority? defaultPriority,
  ) async {
    // Get default priority from context
    final nowBloc = context.read<NowBloc>();
    final currentPriority = nowBloc.state is NowLoaded
        ? (nowBloc.state as NowLoaded).priority
        : null;
    final initialPriority =
        defaultPriority ?? currentPriority ?? await Priority.getDefault();

    return FormData(
      title: 'Add ${_formatTwistName(twist.name, twist.environment)}',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              builder: (context) => TwistDetails(twist: twist),
            ),
            FormSelect<Priority>(
              key: 'priority',
              label: 'Priority',
              initialValue: initialPriority,
              items: (search) =>
                  Priority.get(order: PriorityOrder.nested, search: search),
              titleBuilder: (p) => p.title,
              subtitleBuilder: (p) => p.ancestorsLabel(),
            ),
            FormButton(
              key: 'add',
              command: AddTwist(initialPriority, twist),
              onSubmit: (context, values) async {
                final selectedPriority = values['priority'] as Priority;
                final command = AddTwist(selectedPriority, twist);
                if (!context.mounted) {
                  return const CommandSkipped();
                }
                return await command.run(context);
              },
            ),
          ],
        ),
      ],
    );
  }
}

class AddTwist extends Command {
  AddTwist(this.priority, this.twist)
    : super(
        title: 'Add Twist',
        eventObject: EventObject.twist,
        eventAction: EventAction.added,
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

      return CommandMessage(
        'Twist "${_formatTwistName(twist.name, twist.environment)}" added successfully',
      );
    } catch (e, t) {
      log.warning('Failed to add twist', e, t);
      return CommandMessage('Failed to add twist', isError: true);
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
      await TwistApi.removeTwist(twist.id.toString());

      return CommandMessage(
        'Twist "${_formatTwistName(twist.name, twist.twistEnvironment)}" removed successfully',
      );
    } catch (e, t) {
      log.warning('Failed to remove twist', e, t);
      return CommandMessage('Failed to remove twist', isError: true);
    }
  }
}

class ArchiveActivitiesCreatedByTwist extends ShowForm {
  ArchiveActivitiesCreatedByTwist(this.twist)
    : super(
        title: 'Archive Activities',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(context, twist),
      );

  final PriorityTwist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist twist,
  ) async {
    // Query the count of activities created by this twist
    final count = await _getActivityCount(twist.id);

    return FormData(
      title: 'Archive Activities Created by Twist',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              builder: (context) => SelectableText(
                count == 0
                    ? 'No activities were created by this twist.'
                    : count == 1
                    ? '1 activity was created by this twist and will be archived.'
                    : '$count activities were created by this twist and will be archived.',
                style: context.theme.typography.base,
              ),
            ),
            if (count > 0)
              FormButton(
                key: 'archive',
                command: _ArchiveActivitiesCommand(twist, count),
                onSubmit: (context, values) async {
                  final command = _ArchiveActivitiesCommand(twist, count);
                  if (!context.mounted) {
                    return const CommandSkipped();
                  }
                  return await command.run(context);
                },
              ),
          ],
        ),
      ],
    );
  }

  static Future<int> _getActivityCount(Uuid priorityTwistId) async {
    try {
      final result =
          await Base.client
                  .from('user_activity')
                  .select('id')
                  .eq('created_by', priorityTwistId.toString())
                  .isFilter('archived_at', null)
              as List<dynamic>;

      return result.length;
    } catch (e, t) {
      log.warning('Failed to count activities', e, t);
      return 0;
    }
  }
}

class _ArchiveActivitiesCommand extends Command {
  _ArchiveActivitiesCommand(this.twist, this.count)
    : super(
        title: 'Archive Activities',
        eventObject: EventObject.activity,
        eventAction: EventAction.archived,
      );

  final PriorityTwist twist;
  final int count;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // Execute bulk archive operation
      await Base.client
          .from('activity')
          .update({'archived_at': DateTime.now().toUtc().toIso8601String()})
          .eq('created_by', twist.id.toString())
          .isFilter('archived_at', null);

      return CommandMessage(
        count == 1 ? '1 activity archived' : '$count activities archived',
      );
    } catch (e, t) {
      log.warning('Failed to archive activities', e, t);
      return CommandMessage('Failed to archive activities', isError: true);
    }
  }
}
