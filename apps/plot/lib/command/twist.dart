import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/now.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/twist_api.dart';
import 'package:plot/widget/widget.dart';
import 'logging.dart';

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

    // Fetch priorities for each twist to get their paths
    final editCommandsFutures = priorityTwists.map((twist) async {
      final twistPriority = await Priority.getOne(twist.priorityId);
      return EditTwistCommand(twist, priority: twistPriority);
    });
    final editCommands = await Future.wait(editCommandsFutures);

    // Sort active twists by name, then priority path, then environment
    editCommands.sort((a, b) {
      // Primary: alphabetical by name (case-insensitive)
      final nameComparison = a.priorityTwist.name.toLowerCase().compareTo(
        b.priorityTwist.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;

      // Secondary: priority path (case-insensitive)
      final aPath = a.priority?.root == true
          ? ''
          : (a.priority?.ancestorsLabel() ?? a.priority?.title ?? '');
      final bPath = b.priority?.root == true
          ? ''
          : (b.priority?.ancestorsLabel() ?? b.priority?.title ?? '');
      final pathComparison = aPath.toLowerCase().compareTo(bPath.toLowerCase());
      if (pathComparison != 0) return pathComparison;

      // Tertiary: environment (public, review, private, personal)
      return _compareEnvironment(
        a.priorityTwist.twistEnvironment,
        b.priorityTwist.twistEnvironment,
      );
    });

    final addCommands = allTwists
        .map((twist) => ShowTwistInfo(twist, defaultPriority: priority))
        .toList();

    // Sort available twists by name, then environment
    addCommands.sort((a, b) {
      // Primary: alphabetical by name (case-insensitive)
      final nameComparison = a.twist.name.toLowerCase().compareTo(
        b.twist.name.toLowerCase(),
      );
      if (nameComparison != 0) return nameComparison;

      // Secondary: environment (public, review, private, personal)
      return _compareEnvironment(a.twist.environment, b.twist.environment);
    });

    return Commands(
      groups: [
        StaticCommandGroup(
          title: 'Active Twists',
          commands: editCommands.toList(),
        ),
        StaticCommandGroup(title: 'Available Twists', commands: addCommands),
      ],
    );
  }

  /// Compare environments in order: public, review, private, personal
  static int _compareEnvironment(String a, String b) {
    const envOrder = ['public', 'review', 'private', 'personal'];
    final aIndex = envOrder.indexOf(a);
    final bIndex = envOrder.indexOf(b);

    // If an environment is not in the list, put it at the end
    final aVal = aIndex == -1 ? envOrder.length : aIndex;
    final bVal = bIndex == -1 ? envOrder.length : bIndex;

    return aVal.compareTo(bVal);
  }
}

class EditTwistCommand extends ShowForm {
  EditTwistCommand(this.priorityTwist, {this.priority})
    : super(
        title: priorityTwist.name,
        subtitle: priority?.root == true
            ? null
            : (priority?.ancestorsLabel() ?? priority?.title),
        icon: PlotIcon.settings,
        form: (context) => _buildForm(context, priorityTwist, priority),
      );

  final PriorityTwist priorityTwist;
  final Priority? priority;

  static Future<FormData> _buildForm(
    BuildContext context,
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
        (a) => a.id == priorityTwist.twistId.toString(),
        orElse: () => throw Exception('Twist not found'),
      );

      return FormData(
        title: 'Edit ${priorityTwist.name}',
        groups: [
          StaticFormGroup(
            items: [
              FormInfo(
                key: 'info',
                divider: true,
                builder: (context) => TwistDetails(
                  twist: matchingTwist,
                  priority: loadedPriority,
                ),
              ),
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: priorityTwist.name,
                required: true,
              ),
              FormButton(
                key: 'save',
                buildCommand: (values) {
                  final name = values['name'] as String;
                  return EditTwistName(priorityTwist, name: name);
                },
              ),
              FormDivider(key: 'divider'),
              FormButton(
                key: 'archive',
                buildCommand: (_) => PromptToArchiveTwist(priorityTwist),
              ),
            ],
          ),
        ],
      );
    } catch (e, t) {
      log.warning('Error loading twist details', e, t);
      // Fallback to simple form without details
      return FormData(
        title: 'Edit ${priorityTwist.name}',
        groups: [
          StaticFormGroup(
            items: [
              FormTextInput(
                key: 'name',
                label: 'Name',
                initialValue: priorityTwist.name,
                required: true,
              ),
              FormButton(
                key: 'save',
                buildCommand: (values) {
                  final name = values['name'] as String;
                  return EditTwistName(priorityTwist, name: name);
                },
              ),
              FormDivider(key: 'divider'),
              FormButton(
                key: 'archive',
                buildCommand: (_) => PromptToArchiveTwist(priorityTwist),
              ),
            ],
          ),
        ],
      );
    }
  }
}

class ShowTwistInfo extends ShowForm {
  ShowTwistInfo(this.twist, {Priority? defaultPriority})
    : super(
        title: _formatTwistName(twist.name, twist.environment),
        subtitle: twist.description,
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
      title: twist.name,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              divider: true,
              builder: (context) => TwistDetails(twist: twist),
            ),
            FormTextInput(
              key: 'name',
              label: 'Name',
              initialValue: twist.name,
              required: true,
            ),
            FormSelect<Priority>(
              key: 'priority',
              label: 'Priority',
              initialValue: initialPriority,
              items: (search) =>
                  Priority.get(order: PriorityOrder.nested, search: search),
              labelBuilder: (p) => PriorityLabel(priority: p),
              titleBuilder: (p) => p.ancestorsLabel() != null
                  ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
                  : p.title,
            ),
            FormButton(
              key: 'add',
              buildCommand: (values) {
                final selectedPriority = values['priority'] as Priority;
                final name = values['name'] as String;
                return AddTwist(selectedPriority, twist, name: name);
              },
            ),
          ],
        ),
      ],
    );
  }

  /// Formats twist name with environment label if not public
  static String _formatTwistName(String name, String environment) {
    if (environment == 'public') {
      return name;
    }
    final envLabel = environment[0].toUpperCase() + environment.substring(1);
    return '$name ($envLabel)';
  }
}

class AddTwist extends Command {
  AddTwist(this.priority, this.twist, {required this.name})
    : super(
        title: 'Add Twist',
        icon: PlotIcon.add,
        eventObject: EventObject.twist,
        eventAction: EventAction.added,
      );

  final Priority priority;
  final Twist twist;
  final String name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.addTwist(
        priorityId: priority.id.toString(),
        twistId: twist.id,
        twistEnvironment: twist.environment,
        name: name,
      );

      return CommandMessage('Twist "$name" added successfully');
    } catch (e, t) {
      log.warning('Failed to add twist', e, t);
      if (e is ApiException) {
        return CommandMessage(e.description, title: e.title, isError: true);
      }
      return CommandMessage(e.toString(), isError: true);
    }
  }
}

class EditTwistName extends Command {
  EditTwistName(this.priorityTwist, {this.name})
    : super(
        title: 'Save',
        icon: FontAwesomeIcons.floppyDisk,
        eventObject: EventObject.twist,
        eventAction: EventAction.updated,
      );

  final PriorityTwist priorityTwist;
  final String? name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      if (name == null) {
        return CommandMessage('Name is required', isError: true);
      }

      await TwistApi.updateTwist(
        priorityTwistId: priorityTwist.id.toString(),
        name: name!,
      );

      return CommandMessage('Twist name updated to "${name!}"');
    } catch (e, t) {
      log.warning('Failed to update twist name', e, t);
      return CommandMessage('Failed to update twist name', isError: true);
    }
  }
}

class RemoveTwist extends Command {
  RemoveTwist(this.twist)
    : super(
        title: 'Remove Twist',
        subtitle: 'Remove ${twist.name} from this priority',
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
        icon: FontAwesomeIcons.trash,
      );

  final PriorityTwist twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.removeTwist(twist.id.toString());

      return CommandMessage('Twist "${twist.name}" removed successfully');
    } catch (e, t) {
      log.warning('Failed to remove twist', e, t);
      return CommandMessage('Failed to remove twist', isError: true);
    }
  }
}

class PromptToArchiveTwist extends ShowForm {
  PromptToArchiveTwist(this.twist)
    : super(
        title: 'Archive',
        icon: PlotIcon.archived,
        form: (context) => _buildForm(context, twist),
      );

  final PriorityTwist twist;

  static Future<FormData> _buildForm(
    BuildContext context,
    PriorityTwist twist,
  ) async {
    return FormData(
      title: 'Archive Twist',
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text:
                  'Archiving this twist will remove it and archive the activities it has created.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'archive',
              buildCommand: (_) => _ArchiveTwistCommand(twist),
            ),
          ],
        ),
      ],
    );
  }
}

class _ArchiveTwistCommand extends Command {
  _ArchiveTwistCommand(this.twist)
    : super(
        title: 'Archive Twist',
        icon: PlotIcon.archived,
        eventObject: EventObject.twist,
        eventAction: EventAction.archived,
      );

  final PriorityTwist twist;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await TwistApi.archiveAndRemoveTwist(twist.id.toString());

      // Update local database to immediately reflect the archive
      await Store.get.save(
        PriorityTwist.table,
        twist.copyWith(
          archivedAt: Value(DateTime.now()),
          updatedAt: DateTime.now(),
        ),
        PriorityTwistsBase(),
      );

      return CommandMessage(
        'Twist "${twist.name}" and its activities archived successfully',
      );
    } catch (e, t) {
      log.warning('Failed to archive twist', e, t);
      return CommandMessage('Failed to archive twist', isError: true);
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
              text: count == 0
                  ? 'No activities were created by this twist.'
                  : count == 1
                  ? '1 activity was created by this twist and will be archived.'
                  : '$count activities were created by this twist and will be archived.',
            ),
            if (count > 0)
              FormButton(
                key: 'archive',
                buildCommand: (_) => _ArchiveActivitiesCommand(twist, count),
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
        icon: PlotIcon.archived,
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
