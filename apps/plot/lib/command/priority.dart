import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:auto_route/auto_route.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'command.dart';
import 'activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/page/new_priority.dart';

class PriorityCommand extends ValueCommand<Priority?> {
  PriorityCommand(Priority? priority)
    : super(title: priority?.label ?? 'All Priorities', value: priority);
}

class PriorityCommandGroup extends CommandGroup {
  PriorityCommandGroup() : super(title: 'Priorities');

  @override
  Future<List<Command>> list({String? search}) async {
    final all = await Priority.getAll();
    return all
        .where(
          (priority) =>
              search == null ||
              priority.name.toLowerCase().contains(search.toLowerCase()),
        )
        .map((priority) => PriorityCommand(priority))
        .toList();
  }
}

class PickPriority extends Commands<Priority> {
  PickPriority(List<Priority> priorities, {super.prompt = 'Pick a priority'})
    : super(
        groups: [
          StaticCommandGroup(
            title: 'Recent',
            commands:
                priorities
                    .map((priority) => PriorityCommand(priority))
                    .toList(),
          ),
        ],
        secondaryCommand: (prompt) => NewPriority(),
      );

  PickPriority.recent(BuildContext context, {super.prompt = 'Pick a priority'})
    : super(
        groups: [PriorityCommandGroup()],
        secondaryCommand: (prompt) => NewPriority(),
      );
}

class ChangeCurrentPriority extends Command {
  ChangeCurrentPriority(Priority priority, {bool fullPath = false})
    : priorityId = priority.id,
      super(title: fullPath ? priority.label : priority.name);

  ChangeCurrentPriority.byId({required this.priorityId})
    : super(title: 'View Priority');

  final PriorityId priorityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.push<void>(PriorityRoute(priorityId: priorityId));
    return null;
  }
}

class PickCurrentActivity extends ShowCommand<Priority> {
  PickCurrentActivity()
    : super(
        title: 'Change Current Priority',
        icon: PlotIcon.priority,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        commands:
            (context) =>
                PickPriority.recent(context, prompt: 'Change Current Priority'),
      );

  @override
  void onSelect(BuildContext context, Priority value) async {
    ChangeCurrentPriority(value).run(context);
  }
}

class AddPriority extends Command {
  AddPriority(this._priority) : super(title: 'Add');

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    await priority.copyWith(draft: false).save();
    Posthog().capture(eventName: 'Priority Added');
    if (context.mounted) {
      await context.router.replace(PriorityRoute(priorityId: priority.id));
    }
    return null;
  }
}

class ArchivePriority extends Command {
  ArchivePriority(this._priority)
    : super(title: 'Archive', icon: PlotIcon.delete);

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    final defaultPriority = await Priority.getDefault();
    if (priority == defaultPriority) {
      return CommandMessage(
        'You cannot archive the default priority',
        isError: true,
      );
    }
    await priority.delete();
    Posthog().capture(eventName: 'Priority Archived');
    if (context.mounted) {
      await context.router.replace(
        PriorityRoute(priorityId: priority.parent?.id ?? defaultPriority!.id),
      );
    }
    return null;
  }
}

class NewPriority extends Command {
  NewPriority({this.parent}) : super(title: 'New Priority', icon: PlotIcon.add);

  final Priority? parent;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandPage(NewPriorityPage(parent: parent));
  }
}

StaticCommandGroup priorityCommands(Priority priority) => StaticCommandGroup(
  title: 'Commands',
  commands: [
    ArchivePriority(Future.value(priority)),
    NewActivity(
      draft: Activity.draft(priorityId: priority.id, doAt: DateTime.now()),
    ),
  ],
);
