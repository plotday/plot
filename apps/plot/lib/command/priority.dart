import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'command.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/now.dart';
import 'package:plot/util/theme_color.dart';

abstract class PriorityCommand extends Command {
  PriorityCommand(
    this.priority, {
    required super.eventObject,
    required super.eventAction,
    bool ancestry = true,
  }) : super(
         title: priority?.title ?? 'None',
         subtitle: ancestry ? priority?.ancestorsLabel() : null,
       );

  final Priority? priority;

  @override
  Widget buildBody(BuildContext context) {
    return Row(
      children: [
        if (priority?.ancestorsLabel() != null) ...[
          Flexible(
            child: Text(
              priority!.ancestorsLabel()!,
              overflow: TextOverflow.ellipsis,
              style: context.theme.typography.base.copyWith(
                color: context.theme.plotColors.muted,
              ),
            ),
          ),
          Text(
            Priority.separator,
            style: context.theme.typography.base.copyWith(
              color: context.theme.plotColors.muted,
            ),
          ),
        ],
        Flexible(
          child: Text(
            priority?.title ?? 'None',
            overflow: TextOverflow.ellipsis,
            style: context.theme.typography.base.copyWith(
              color: context.theme.colors.foreground,
            ),
          ),
        ),
      ],
    );
  }
}

class ChangeCurrentPriority extends PriorityCommand {
  ChangeCurrentPriority(Priority super.priority, {super.ancestry = true})
    : super(eventObject: EventObject.priority, eventAction: EventAction.viewed);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandRoute(
      PriorityRoute(priorityIdString: priority!.id.toShortString()),
    );
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
             builder: (priority) => ChangeCurrentPriority(priority!),
           ),
         ],
         secondaryCommand: (prompt) => NewPriority(parent: initialPriority),
       );
}

class OpenPriority extends Command {
  OpenPriority(Priority priority)
    : priorityId = priority.id,
      super(
        title: "Open",
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
        icon: PlotIcon.open,
      );

  OpenPriority.byId(this.priorityId)
    : super(
        title: "Open",
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
        icon: PlotIcon.open,
      );

  final PriorityId priorityId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandRoute(
      PriorityRoute(priorityIdString: priorityId.toShortString()),
    );
  }
}

class PickCurrentPriority extends ShowCommands {
  PickCurrentPriority()
    : super(
        title: 'Switch Priorities',
        icon: PlotIcon.priority,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        commands: (context) => Future.value(ChangeCurrentPriorityCommands()),
      );
}

class AddPriority extends Command {
  AddPriority(this._priority)
    : super(
        title: 'Add',
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    final savedPriority = await priority.save();
    return CommandRoute(
      PriorityRoute(priorityIdString: savedPriority.id.toShortString()),
      replace: true,
    );
  }
}

class EditPriority extends Command {
  EditPriority(this._priority)
    : super(
        title: 'Save',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    await priority.save();
    return const CommandDone();
  }
}

class ArchivePriority extends Command {
  ArchivePriority(this._priority)
    : super(
        title: 'Archive',
        eventObject: EventObject.priority,
        eventAction: EventAction.archived,
        icon: PlotIcon.archived,
      );

  final Future<Priority> _priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    if (priority.root) {
      return CommandMessage(
        "The default priority can't be archived",
        isError: true,
      );
    }
    await priority.delete();
    return const CommandDone();
  }
}

class NewPriority extends ShowForm {
  NewPriority({Priority? parent})
    : super(
        title: parent == null ? 'Add a Priority' : 'Add a Sub-priority',
        icon: PlotIcon.add,
        form: (context) async {
          // Get default parent for the dummy action (only used for display)
          final prioritiesBloc = context.read<PrioritiesBloc>();
          final nowBloc = context.read<NowBloc>();
          final currentPriority = nowBloc.state is NowLoaded
              ? (nowBloc.state as NowLoaded).priority
              : null;
          final defaultParent =
              parent ??
              currentPriority ??
              prioritiesBloc.state.root ??
              await Priority.getDefault();

          return FormData(
            title: parent == null ? 'Add a Priority' : 'Add a Sub-priority',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Priority Name',
                    required: true,
                    autofocus: true,
                  ),
                  FormSelect<Priority>(
                    key: 'parent',
                    label: 'Parent',
                    initialValue: defaultParent,
                    items: (search) => Priority.get(
                      order: PriorityOrder.nested,
                      search: search,
                    ),
                    labelBuilder: (p) => PriorityLabel(
                      priority: p,
                      fontSize: 12,
                    ),
                    titleBuilder: (p) => p.ancestorsLabel() != null
                        ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
                        : p.title,
                  ),
                  FormSelect<ThemeColor?>(
                    key: 'color',
                    label: 'Color',
                    initialValue: null,
                    hasInitialValue: true,
                    items: (search) async => [null, ...ThemeColor.options]
                        .where(
                          (c) =>
                              search == null ||
                              (c?.label.toLowerCase() ?? 'inherit').startsWith(
                                search.toLowerCase(),
                              ),
                        )
                        .toList(),
                    titleBuilder: (c) => c?.label ?? 'Inherit',
                    leadingBuilder: (c) =>
                        ColorDot(color: c ?? defaultParent.displayColor),
                  ),
                  FormButton(
                    key: 'create',
                    command: AddPriority(
                      Future.value(
                        Priority(title: '', parent: defaultParent, draft: true),
                      ),
                    ),
                    onSubmit: (context, values) async {
                      final title = values['title'] as String;
                      final selectedParent = values['parent'] as Priority;
                      final color = values['color'] as ThemeColor?;
                      final command = AddPriority(
                        Future.value(
                          Priority(
                            title: title,
                            parent: selectedParent,
                            color: color,
                            draft: true,
                          ),
                        ),
                      );
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
        },
      );
}

class EditPriorityCommand extends ShowForm {
  EditPriorityCommand(Priority priority)
    : super(
        title: 'Edit',
        icon: PlotIcon.settings,
        form: (context) async {
          final isRoot = priority.root;
          // Load parent if not already loaded (parent might be null even when priority has ancestors)
          Priority? parent = priority.parent;
          if (parent == null && priority.parentId != null) {
            parent = await Priority.getOne(priority.parentId!);
          }

          return FormData(
            title: 'Edit Priority',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Priority Name',
                    initialValue: priority.title,
                    required: true,
                    autofocus: true,
                  ),
                  FormSelect<Priority>(
                    key: 'parent',
                    label: 'Parent',
                    initialValue: parent,
                    enabled: !isRoot,
                    placeholder: 'None',
                    items: (search) async {
                      final priorities = await Priority.get(
                        order: PriorityOrder.nested,
                        search: search,
                      );
                      // Filter out the priority itself and its descendants
                      return priorities
                          .where(
                            (p) =>
                                p.id != priority.id &&
                                !priority.path.isParent(p.path),
                          )
                          .toList();
                    },
                    titleBuilder: (p) => p.title,
                    subtitleBuilder: (p) => p.ancestorsLabel(),
                  ),
                  FormSelect<ThemeColor?>(
                    key: 'color',
                    label: 'Color',
                    initialValue: isRoot
                        ? (priority.color ?? const ThemeColor.defaultColor())
                        : priority.color,
                    hasInitialValue: true,
                    items: (search) async =>
                        (isRoot
                                ? ThemeColor.options
                                : [null, ...ThemeColor.options])
                            .where(
                              (c) =>
                                  search == null ||
                                  (c?.label.toLowerCase() ?? 'inherit')
                                      .startsWith(search.toLowerCase()),
                            )
                            .toList(),
                    titleBuilder: (c) => c?.label ?? 'Inherit',
                    leadingBuilder: (c) => ColorDot(
                      color:
                          c ??
                          parent?.displayColor ??
                          const ThemeColor.defaultColor(),
                    ),
                  ),
                  FormButton(
                    key: 'save',
                    command: EditPriority(Future.value(priority)),
                    onSubmit: (context, values) async {
                      final title = values['title'] as String;
                      final newParent = values['parent'] as Priority?;
                      final color = values['color'] as ThemeColor?;
                      final updatedPriority = priority.copyWith(
                        title: title,
                        parent: newParent,
                        color: Value(color),
                      );
                      await updatedPriority.save();
                      return const CommandDone();
                    },
                  ),
                ],
              ),
            ],
          );
        },
      );
}

class ShowPriorityCommands extends ShowCommands {
  ShowPriorityCommands(Priority priority, {bool current = false})
    : super(
        title: 'More Commands',
        icon: PlotIcon.menu,
        commands: (context) => Future.value(
          Commands(
            groups: [
              StaticCommandGroup(
                title: priority.title,
                commands: current
                    ? currentPriorityCommands(priority)
                    : priorityCommands(priority),
              ),
            ],
          ),
        ),
      );
}

List<Command> prioritySecondaryCommands(Priority priority) => [
  EditPriorityCommand(priority),
  if (!priority.root) SetTopPriority(priority, priority.topOrder == null),
  if (!priority.root) ArchivePriority(Future.value(priority)),
];

List<Command> priorityCommands(Priority priority) => [
  OpenPriority(priority),
  ...prioritySecondaryCommands(priority),
];

List<Command> currentPriorityCommands(Priority priority) => [
  ...prioritySecondaryCommands(priority),
  NewActivity(),
  NextActivityThread(),
  PreviousActivityThread(),
];

class SetTopPriority extends Command {
  SetTopPriority(this.priority, this.add)
    : super(
        title: add ? 'Add to Top Priorities' : 'Remove from Top Priorities',
        eventObject: EventObject.priority,
        eventAction: add ? EventAction.pinned : EventAction.unpinned,
        icon: add ? PlotIcon.pin : PlotIcon.unpin,
      );

  final Priority priority;
  final bool add;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await priority
        .copyWith(topOrder: add ? Value(Order.first()) : const Value(null))
        .save();
    return const CommandDone();
  }
}

class ToggleShowArchived extends Command {
  ToggleShowArchived({required this.showArchived})
    : super(
        title: showArchived ? 'Show Active Items' : 'Show Archived Items',
        subtitle: showArchived ? 'Hide archived items' : 'Show archived items',
        eventObject: EventObject.archived,
        eventAction: EventAction.viewed,
        icon: PlotIcon.archived,
      );

  final bool showArchived;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleShowArchived();
    return const CommandDone();
  }
}
