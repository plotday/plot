import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'command.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/page/edit_priority.dart';
import 'package:plot/state/priority.dart';

abstract class PriorityCommand extends Command {
  PriorityCommand(this.priority)
    : super(
        title: priority?.title ?? 'None',
        subtitle: priority?.ancestorsLabel(),
      );

  final Priority? priority;

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        if (priority?.ancestorsLabel().isNotEmpty == true) ...[
          Flexible(
            child: Text(
              priority!.ancestorsLabel(),
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
            priority?.title ?? 'None',
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

class ChangeCurrentPriority extends PriorityCommand {
  ChangeCurrentPriority(super.priority);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandRoute(PriorityRoute(priorityId: priority?.id));
  }
}

class PriorityGroup extends CommandGroup {
  PriorityGroup({required super.title, required this.builder});

  final Command Function(Priority? priority) builder;

  @override
  Future<List<Command>> list({String? search}) async {
    final all = (await Priority.get(
      order: PriorityOrder.recent,
      search: search,
    )).map((priority) => builder(priority)).toList();
    return CommandGroup.filter(all, search);
  }
}

class ChangeCurrentPriorityCommands extends Commands {
  ChangeCurrentPriorityCommands({
    super.prompt = 'Change Current Priority',
    Priority? initialPriority,
  }) : super(
         groups: [
           PriorityGroup(
             title: 'Change Current Priority',
             builder: (priority) => ChangeCurrentPriority(priority),
           ),
         ],
         secondaryCommand: (prompt) => NewPriority(parent: initialPriority),
       );
}

class OpenPriority extends Command {
  OpenPriority(Priority priority)
    : priorityId = priority.id,
      super(title: "Open", icon: PlotIcon.open);

  OpenPriority.byId(this.priorityId)
    : super(title: "Open", icon: PlotIcon.open);

  final PriorityId priorityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandRoute(PriorityRoute(priorityId: priorityId));
  }
}

class PickCurrentPriority extends ShowCommands {
  PickCurrentPriority()
    : super(
        title: 'Pick Current Priority',
        icon: PlotIcon.priority,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        commands: (context) => Future.value(ChangeCurrentPriorityCommands()),
      );
}

class AddPriority extends Command {
  AddPriority(this._priority) : super(title: 'Add');

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    await priority.save();
    Posthog().capture(eventName: 'Priority Added');
    return CommandRoute(PriorityRoute(priorityId: priority.id), replace: true);
  }
}

class EditPriority extends Command {
  EditPriority(this._priority) : super(title: 'Save');

  final Future<Priority> _priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final priority = await _priority;
    await priority.save();
    Posthog().capture(eventName: 'Priority Edited');
    return null;
  }
}

class ArchivePriority extends Command {
  ArchivePriority(this._priority)
    : super(title: 'Archive', icon: PlotIcon.archive);

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
  NewPriority({this.parent})
    : super(title: 'New Sub-priority', icon: PlotIcon.add);

  final Priority? parent;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandPage(EditPriorityPage(parent: parent));
  }
}

class EditPriorityCommand extends Command {
  EditPriorityCommand(this.priority)
    : super(title: 'Edit', icon: PlotIcon.settings);

  final Priority priority;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    return CommandPage(EditPriorityPage(priority: priority));
  }
}

class ShowPriorityCommands extends ShowCommands {
  ShowPriorityCommands(Priority priority)
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: (context) => Future.value(
          Commands(
            groups: [
              StaticCommandGroup(
                title: priority.title,
                commands: priorityCommands(priority),
              ),
            ],
          ),
        ),
      );
}

List<Command> prioritySecondaryCommands(Priority priority) => [
  EditPriorityCommand(priority),
  if (!priority.root) ArchivePriority(Future.value(priority)),
];

List<Command> priorityCommands(Priority priority) => [
  OpenPriority(priority),
  ...prioritySecondaryCommands(priority),
];

List<Command> currentPriorityCommands(Priority priority) => [
  ...prioritySecondaryCommands(priority),
  NewPriority(parent: priority),
];

class ToggleShowArchived extends Command {
  ToggleShowArchived({required this.showArchived})
    : super(
        title: showArchived ? 'Show Active Items' : 'Show Archived Items',
        subtitle: showArchived ? 'Hide archived items' : 'Show archived items',
        icon: showArchived ? PlotIcon.hideArchived : PlotIcon.unarchive,
      );

  final bool showArchived;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final bloc = context.read<PriorityBloc>();
    bloc.toggleShowArchived();
    return null;
  }
}

final prioritiesCommands = StaticCommandGroup(
  title: 'Current Priority',
  commands: [PickCurrentPriority()],
);
