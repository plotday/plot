import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'logging.dart';
import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/page/new_priority.dart';

class _PriorityValue extends ValueCommand<Priority?> {
  _PriorityValue(Priority? priority)
    : super(
        title: priority?.title ?? 'None',
        subtitle: priority?.ancestorsLabel(),
        value: priority,
      );

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        if (value?.ancestorsLabel().isNotEmpty == true) ...[
          Flexible(
            child: Text(
              value!.ancestorsLabel(),
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.xs.copyWith(
                color: context.colour.muted,
              ),
            ),
          ),
          Text(
            Priority.separator,
            style: context.theme.typography.xs.copyWith(
              color: context.colour.muted,
            ),
          ),
        ],
        Flexible(
          child: Text(
            value?.title ?? 'None',
            overflow: TextOverflow.ellipsis,
            style: context.theme.typography.xs.copyWith(
              color: context.colour.foreground,
            ),
          ),
        ),
      ],
    );
  }
}

class PriorityCommandGroup extends CommandGroup {
  PriorityCommandGroup() : super(title: 'Priorities');

  @override
  Future<List<Command>> list({String? search}) async {
    final all =
        (await Priority.get(
          order: PriorityOrder.recent,
          search: search,
        )).map((priority) => _PriorityValue(priority)).toList();
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

class ChangeCurrentPriority extends Command {
  ChangeCurrentPriority(Priority priority)
    : priorityId = priority.id,
      super(title: "Open", icon: PlotIcon.open);

  ChangeCurrentPriority.byId(this.priorityId)
    : super(title: "Open", icon: PlotIcon.open);

  final PriorityId priorityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.navigate(PriorityRoute(priorityId: priorityId));
    return null;
  }
}

class PickCurrentPriority extends ShowCommands<Priority> {
  PickCurrentPriority()
    : super(
        title: 'Pick Current Priority',
        icon: PlotIcon.priority,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        commands: (context) => PickPriority(prompt: 'Change Current Priority'),
      );

  @override
  void onSelect(BuildContext context, Priority value) async {
    log.info('Change current priority to ${value.title}');
    ChangeCurrentPriority(value).run(context);
  }
}

class AddPriority extends Command {
  AddPriority(this._priority) : super(title: 'Add');

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    await priority.save();
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
    if (priority.root) {
      return CommandMessage(
        'You cannot archive the default priority',
        isError: true,
      );
    }
    await priority.delete();
    Posthog().capture(eventName: 'Priority Archived');
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

class PriorityCommands extends Commands<void> {
  final Priority priority;

  PriorityCommands(this.priority)
    : super(
        groups: [
          StaticCommandGroup(
            title: priority.title,
            commands: priorityCommands(priority),
          ),
        ],
      );
}

class ShowPriorityCommands extends ShowCommands<void> {
  ShowPriorityCommands(Priority priority)
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: (context) => PriorityCommands(priority),
      );
}

Command priorityPrimaryCommand(Priority priority) =>
    ChangeCurrentPriority(priority);

List<Command> prioritySecondaryCommands(Priority priority) => [
  if (!priority.root) ArchivePriority(Future.value(priority)),
];

List<Command> priorityCommands(Priority priority) => [
  NewPriority(parent: priority),
  priorityPrimaryCommand(priority),
  ...prioritySecondaryCommands(priority),
];
