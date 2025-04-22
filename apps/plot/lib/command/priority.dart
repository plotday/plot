import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:auto_route/auto_route.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'logging.dart';
import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/page/new_priority.dart';

class PriorityCommand extends ValueCommand<Priority?> {
  PriorityCommand(Priority? priority)
    : super(
        title: priority?.name ?? 'None',
        subtitle: priority != null ? priority.parent?.pathLabel : 'Top-level',
        value: priority,
      );
}

class PriorityCommandGroup extends CommandGroup {
  PriorityCommandGroup({this.includeNone = false}) : super(title: 'Priorities');

  final bool includeNone;

  @override
  Future<List<Command>> list({String? search}) async {
    final all =
        (await Priority.getAll())
            .map((priority) => PriorityCommand(priority))
            .toList();
    if (includeNone) {
      all.add(PriorityCommand(null));
    }
    return CommandGroup.filter(all, search);
  }
}

class PickPriority extends Commands<Priority> {
  PickPriority({super.prompt = 'Pick a priority', this.initialPriority})
    : super(
        groups: [PriorityCommandGroup()],
        secondaryCommand: (prompt) => NewPriority(parent: initialPriority),
      );

  final Priority? initialPriority;
}

class PickPriorityOrNone extends Commands<Priority?> {
  PickPriorityOrNone({super.prompt = 'Pick a priority', this.initialPriority})
    : super(
        groups: [PriorityCommandGroup(includeNone: true)],
        secondaryCommand: (prompt) => NewPriority(parent: initialPriority),
      );

  final Priority? initialPriority;
}

class ChangeCurrentPriority extends Command {
  ChangeCurrentPriority(Priority priority, {bool fullPath = true})
    : priorityId = priority.id,
      super(title: priority.name, subtitle: priority.parent?.pathLabel);

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
        commands: (context) => PickPriority(prompt: 'Change Current Priority'),
      );

  @override
  void onSelect(BuildContext context, Priority value) async {
    log.info('Change current priority to ${value.name}');
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
  commands: [ArchivePriority(Future.value(priority))],
);
