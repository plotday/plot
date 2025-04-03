import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/router.dart';

class PriorityCommand extends ValueCommand<Priority?> {
  PriorityCommand(
    Priority? priority,
  ) : super(
          title: priority?.name ?? 'All Priorities',
          icon: PlotIcon.priority,
          value: priority,
        );
}

class PriorityCommandGroup extends CommandGroup {
  PriorityCommandGroup()
      : super(
          title: 'Priorities',
        );

  @override
  Future<List<Command>> list({String? search}) async {
    final all = await Priority.getAll();
    return all
        .where((priority) =>
            search == null ||
            priority.name.toLowerCase().contains(search.toLowerCase()))
        .map((priority) => PriorityCommand(priority))
        .toList();
  }
}

class PickPriority extends Commands<Priority> {
  PickPriority(
    List<Priority> priorities, {
    super.prompt = 'Pick a priority',
  }) : super(groups: [
          StaticCommandGroup(
            title: 'Recent',
            commands: priorities
                .map((priority) => PriorityCommand(priority))
                .toList(),
          ),
        ]);

  PickPriority.recent(
    BuildContext context, {
    super.prompt = 'Pick a priority',
  }) : super(groups: [PriorityCommandGroup()]);
}

class ChangeCurrentPriority extends Command {
  ChangeCurrentPriority(Priority priority)
      : priorityId = priority.id,
        super(
          title: priority.name,
          icon: PlotIcon.priority,
        );

  ChangeCurrentPriority.byId({required this.priorityId})
      : super(
          title: 'View Priority',
          icon: PlotIcon.priority,
        );

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
          shortcut: const SingleActivator(
            LogicalKeyboardKey.keyJ,
            meta: true,
          ),
          commands: (context) => PickPriority.recent(
            context,
            prompt: 'Change Current Priority',
          ),
        );

  @override
  void onSelect(BuildContext context, Priority value) async {
    print("Go priority ${value.name}");
    ChangeCurrentPriority(value).run(context);
  }
}

class AddPriority extends Command {
  AddPriority(this._priority)
      : super(
          title: 'Add',
        );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    await priority.copyWith(draft: false).save();
    Posthog().capture(
      eventName: 'Priority Added',
    );
    if (context.mounted) {
      await context.router.replace(PriorityRoute(priorityId: priority.id));
    }
    return null;
  }
}

class ArchivePriority extends Command {
  ArchivePriority(this._priority)
      : super(
          title: 'Archive',
        );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    final defaultPriority = await Priority.getDefault();
    if (priority == defaultPriority) {
      return CommandMessage('You cannot archive the default priority',
          isError: true);
    }
    await priority.delete();
    Posthog().capture(
      eventName: 'Priority Archived',
    );
    if (context.mounted) {
      await context.router.replace(PriorityRoute(
          priorityId: priority.parent?.id ?? defaultPriority!.id));
    }
    return null;
  }
}

class NewPriority extends Command {
  NewPriority()
      : super(
          title: 'New Priority',
          icon: PlotIcon.add,
        );

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.push<void>(
        NewPriorityRoute(priorityId: context.read<PriorityBloc>().currentId));
    return null;
  }
}

StaticCommandGroup priorityCommands(Priority priority) =>
    StaticCommandGroup(title: 'Commands', commands: [
      ArchivePriority(Future.value(priority)),
    ]);
