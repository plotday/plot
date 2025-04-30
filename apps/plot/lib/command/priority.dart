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
        title: priority?.label ?? 'None',
        subtitle: priority != null ? priority.parent?.pathLabel : 'Top-level',
        value: priority,
      );
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
  ChangeCurrentPriority(Priority priority, {bool fullPath = true})
    : priorityId = priority.id,
      super(title: priority.label, subtitle: priority.parent?.pathLabel);

  ChangeCurrentPriority.byId({required this.priorityId})
    : super(title: 'View Priority');

  final PriorityId priorityId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.push<void>(PriorityRoute(priorityId: priorityId));
    return null;
  }
}

class PickCurrentPriority extends ShowCommand<Priority> {
  PickCurrentPriority()
    : super(
        title: 'Change Current Priority',
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
    if (priority.root) {
      return CommandMessage(
        'You cannot archive the default priority',
        isError: true,
      );
    }
    await priority.delete();
    Posthog().capture(eventName: 'Priority Archived');
    if (context.mounted) {
      await context.router.replace(
        PriorityRoute(priorityId: priority.parent?.id ?? defaultPriority.id),
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

abstract class _UpdatePriorityCommand extends Command {
  _UpdatePriorityCommand(
    this.priority, {
    Future<void> Function(Priority)? onUpdate,
    required super.title,
    super.icon,
  }) : onUpdate = onUpdate ?? ((priority) => priority.save());

  final Priority priority;
  final Future<void> Function(Priority) onUpdate;
}

class StartPriority extends _UpdatePriorityCommand {
  StartPriority(super.priority, {super.onUpdate})
    : super(title: 'Do Now', icon: PlotIcon.doNow);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final start = !priority.doNow;
    await onUpdate(
      priority.copyWith(
        doAt:
            start
                ? Value(DateTime.now().subtract(Duration(seconds: 10)))
                : const Value(null),
      ),
    );
    Posthog().capture(
      eventName: start ? 'Priority Started' : 'Priority Stopped',
    );
    return null;
  }
}

class FinishPriority extends _UpdatePriorityCommand {
  FinishPriority(super.priority, {super.onUpdate})
    : super(title: 'Finish Priority', icon: PlotIcon.done);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(priority.copyWith(doneAt: Value(DateTime.now())));
    Posthog().capture(eventName: 'Priority Finished');
    return null;
  }
}

class MarkPriorityIncomplete extends _UpdatePriorityCommand {
  MarkPriorityIncomplete(super.priority, {super.onUpdate})
    : super(title: 'Mark Priority Not Finished', icon: PlotIcon.done);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(priority.copyWith(doneAt: const Value(null)));
    Posthog().capture(eventName: 'Priority Marked Not Finished');
    return null;
  }
}

class PinPriority extends _UpdatePriorityCommand {
  PinPriority(super.priority, {super.onUpdate})
    : super(title: priority.pinned ? 'Unpin' : 'Pin', icon: PlotIcon.pinned);

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await onUpdate(priority.copyWith(pinned: !priority.pinned));
    Posthog().capture(
      eventName: priority.pinned ? 'Priority Un-pinned' : 'Priority Pinned',
    );
    return null;
  }
}

StaticCommandGroup priorityCommands(Priority priority) => StaticCommandGroup(
  title: 'Commands',
  commands: [ArchivePriority(Future.value(priority))],
);

Command priorityCommand(Priority priority) => CommandWrapper(
  switch (priority) {
    _ when priority.pinned => PinPriority(priority),
    _ when priority.doNow => FinishPriority(priority),
    _ when priority.done => MarkPriorityIncomplete(priority),
    _ => StartPriority(priority),
  },
  statusIcon: Value(switch (priority) {
    _ when priority.pinned => PlotIcon.pinned,
    _ when priority.doNow => PlotIcon.todo,
    _ when priority.done => PlotIcon.done,
    _ => PlotIcon.doNow,
  }),
);
