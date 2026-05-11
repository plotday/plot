import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'command.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/router.dart';

abstract class PriorityCommand extends Command {
  PriorityCommand(
    this.priority, {
    required super.eventObject,
    required super.eventAction,
    bool ancestry = true,
  }) : super(
         title: priority?.title ?? 'None',
         subtitle: ancestry
             ? (priority?.root == true
                   ? null
                   : (priority?.ancestorsLabel() ?? priority?.title))
             : null,
       );

  final Priority? priority;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) => null;

  @override
  Widget? buildBody(BuildContext context) {
    if (priority == null) return null;
    return PriorityLabel(priority: priority!);
  }
}

class ChangeCurrentPriority extends PriorityCommand {
  ChangeCurrentPriority(Priority super.priority, {super.ancestry = true})
    : super(eventObject: EventObject.priority, eventAction: EventAction.viewed);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Flip the priority highlight immediately instead of waiting for the
    // new PriorityBloc to finish loading drafts and emit its new context.
    final nowBloc = context.read<NowBloc>();
    if (nowBloc.state is NowLoaded) {
      // Selecting a priority is an explicit "show me this priority"
      // action, so clear any sticky event selection — even when the
      // chosen priority is the same as the event's priority (setContext
      // would otherwise preserve it).
      nowBloc.setCurrentEvent(null);
      nowBloc.setContext(priority);
    }
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
    final priorities = await Priority.get(
      order: PriorityOrder.recent,
      search: search,
    );
    final all = priorities.map((priority) => builder(priority)).toList();
    return CommandGroup.filter(all, search);
  }
}

class ChangeCurrentPriorityCommands extends Commands {
  ChangeCurrentPriorityCommands({Priority? initialPriority})
    : super(
        groups: [
          PriorityGroup(
            title: 'Priorities',
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
        title: 'Switch priorities',
        icon: PlotIcon.priority,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyP, alt: kIsWeb),
        commands: ChangeCurrentPriorityCommands(),
      );
}

class AddPriority extends Command {
  AddPriority(this._priority)
    : super(
        title: 'Add',
        icon: PlotIcon.add,
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
        icon: FontAwesomeIcons.check,
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

class TogglePriorityArchived extends Command {
  TogglePriorityArchived(Priority priority)
    : _priority = Future.value(priority),
      super(
        title: priority.archivedAt != null ? 'Un-archive' : 'Archive',
        eventObject: EventObject.priority,
        eventAction: priority.archivedAt != null
            ? EventAction.unarchived
            : EventAction.archived,
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
    final isArchived = priority.archivedAt != null;
    await priority
        .copyWith(archivedAt: Value(isArchived ? null : DateTime.now()))
        .save();
    return const CommandDone();
  }
}

/// Builds the FormData for creating a new priority.
/// [submitBuilder] controls what command the form button creates.
Future<FormData> _buildNewPriorityForm(
  BuildContext context, {
  Priority? parent,
  required Command Function(Future<Priority> priority) submitBuilder,
}) async {
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

  final parentSelect = FormSelect<Priority>(
    key: 'parent',
    label: 'Parent',
    initialValue: defaultParent,
    items: (search) async =>
        Priority.get(order: PriorityOrder.nested, search: search),
    labelBuilder: (p) => PriorityLabel(priority: p),
    titleBuilder: (p) => p.ancestorsLabel() != null
        ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
        : p.title,
  );

  return FormData(
    title: parent == null ? 'Add a priority' : 'Add a sub-priority',
    groups: [
      StaticFormGroup(
        items: [
          FormTextInput(key: 'title', label: 'Priority Name', required: true),
          parentSelect,
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
          FormShareSelect(
            key: 'shared',
            label: 'Share new threads',
            placeholder: 'No one',
            priority: defaultParent,
          ),
          FormButton(
            key: 'create',
            isPrimary: true,
            buildCommand: (values) {
              final title = values['title'] as String;
              final selectedParent = values['parent'] as Priority;
              final color = values['color'] as ThemeColor?;
              final shared =
                  (values['shared'] as SharedSelection?) ??
                  const SharedSelection();
              return submitBuilder(
                Future.value(
                  Priority(
                    title: title,
                    parent: selectedParent,
                    color: color,
                    draft: true,
                    defaultContacts: shared.contacts,
                    defaultGroups: shared.groups,
                    defaultInviteEmails: shared.inviteEmails,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    ],
  );
}

class NewPriority extends ShowForm {
  NewPriority({Priority? parent})
    : super(
        title: parent == null || parent.root == true
            ? 'Add a priority'
            : 'Add a sub-priority',
        icon: PlotIcon.add,
        form: (context) => _buildNewPriorityForm(
          context,
          parent: parent,
          submitBuilder: (priority) => AddPriority(priority),
        ),
      );
}

class _SaveAndReturnPriority extends Command {
  _SaveAndReturnPriority(this._priority, {required this.onSaved})
    : super(
        title: 'Add',
        icon: PlotIcon.add,
        eventObject: EventObject.priority,
        eventAction: EventAction.added,
      );

  final Future<Priority> _priority;
  final void Function(Priority) onSaved;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final priority = await _priority;
    final savedPriority = await priority.save();
    onSaved(savedPriority);
    return const CommandDone();
  }
}

/// Opens the new priority form and returns the created Priority, or null if cancelled.
/// Unlike NewPriority command, this doesn't navigate to the new priority.
Future<Priority?> createPriorityInline(
  BuildContext context, {
  Priority? parent,
}) async {
  Priority? result;

  final command = ShowForm(
    title: parent == null || parent.root == true
        ? 'Add a priority'
        : 'Add a sub-priority',
    icon: PlotIcon.add,
    form: (context) => _buildNewPriorityForm(
      context,
      parent: parent,
      submitBuilder: (priorityFuture) =>
          _SaveAndReturnPriority(priorityFuture, onSaved: (p) => result = p),
    ),
  );

  await command.run(context);
  return result;
}

class EditPriorityCommand extends ShowForm {
  EditPriorityCommand(Priority priority)
    : super(
        title: 'Edit priority',
        icon: PlotIcon.settings,
        form: (context) async {
          // Re-fetch priority to get latest data (e.g. after a previous save)
          final p = await Priority.getOne(priority.id);
          final isRoot = p.root;
          // Load parent if not already loaded (parent might be null even when priority has ancestors)
          Priority? parent = p.parent;
          if (parent == null && p.parentId != null) {
            parent = await Priority.getOne(p.parentId!);
          }

          final parentSelect = FormSelect<Priority>(
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
              return priorities.where((candidate) {
                if (candidate.id == p.id) return false;
                if (p.path.isParent(candidate.path)) return false;
                return true;
              }).toList();
            },
            labelBuilder: (item) => PriorityLabel(priority: item),
            titleBuilder: (item) => item.ancestorsLabel() != null
                ? '${item.ancestorsLabel()}${Priority.separator}${item.title}'
                : item.title,
          );

          return FormData(
            title: 'Edit priority',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Priority Name',
                    initialValue: p.title,
                    required: true,
                  ),
                  parentSelect,
                  FormSelect<ThemeColor?>(
                    key: 'color',
                    label: 'Color',
                    initialValue: isRoot
                        ? (p.color ?? const ThemeColor.defaultColor())
                        : p.color,
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
                  FormShareSelect(
                    key: 'shared',
                    label: 'Share new threads',
                    placeholder: 'No one',
                    priority: p,
                    initialValue: SharedSelection(
                      contacts: List<Uuid>.from(p.defaultSharedContacts),
                      groups: List<Uuid>.from(p.defaultSharedGroups),
                      inviteEmails: List<String>.from(
                        p.defaultSharedInviteEmails,
                      ),
                    ),
                  ),
                  FormButton(
                    key: 'save',
                    isPrimary: true,
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      final newParent = values['parent'] as Priority?;
                      final color = values['color'] as ThemeColor?;
                      final shared =
                          (values['shared'] as SharedSelection?) ??
                          const SharedSelection();
                      return EditPriority(
                        Future.value(
                          p.copyWith(
                            title: title,
                            parent: newParent,
                            color: Value(color),
                            defaultContacts: Value(shared.contacts),
                            defaultGroups: Value(shared.groups),
                            defaultInviteEmails: Value(
                              shared.inviteEmails.isEmpty
                                  ? null
                                  : jsonEncode(shared.inviteEmails),
                            ),
                          ),
                        ),
                      );
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
        title: 'More commands',
        icon: PlotIcon.menu,
        commands: Commands(
          groups: current
              ? currentPriorityCommandGroups(priority)
              : priorityCommandGroups(priority),
        ),
      );
}

List<Command> prioritySecondaryCommands(Priority priority) => [
  if (!priority.isViewer && !priority.isPlot) EditPriorityCommand(priority),
  if (!priority.isViewer) ShowAttentionSettings(priority),
  if (!priority.root) SetTopPriority(priority, priority.topOrder == null),
  if (!priority.isViewer) NewPriority(parent: priority),
  if (!priority.root && !priority.isViewer && !priority.isPlot)
    TogglePriorityArchived(priority),
];

List<Command> priorityCommands(Priority priority) => [
  ...prioritySecondaryCommands(priority),
];

List<Command> currentPriorityCommands(
  Priority priority, {
  BuildContext? context,
}) => [
  ...prioritySecondaryCommands(priority),
  if (context != null) ToggleArchivedVisibility(context: context),
  NewThread(),
  OpenNextThread(),
  OpenPreviousThread(),
];

List<StaticCommandGroup> priorityCommandGroups(Priority priority) => [
  StaticCommandGroup(
    title: 'Priority: ${priority.title}',
    commands: priorityCommands(priority),
  ),
];

List<StaticCommandGroup> currentPriorityCommandGroups(
  Priority priority, {
  BuildContext? context,
}) => [
  StaticCommandGroup(
    title: 'Priority: ${priority.title}',
    commands: currentPriorityCommands(priority, context: context),
  ),
];

class SetTopPriority extends Command {
  SetTopPriority(this.priority, this.add)
    : super(
        title: add ? 'Add to top priorities' : 'Remove from top priorities',
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
        title: showArchived ? 'Show active items' : 'Show archived items',
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

/// Toggle archived visibility across the current priority's threads and
/// notes (and, via the priorities-list watcher, archived priorities too).
/// Backed by `showArchived` on `PriorityBloc` (and `ThreadBloc` when a thread
/// is open) so it stays independent of search and filter state.
class ToggleArchivedVisibility extends Command {
  ToggleArchivedVisibility._({required this.showingArchived})
    : super(
        title: showingArchived ? 'Hide archived' : 'Show archived',
        subtitle: showingArchived
            ? 'Hide archived threads, notes and priorities'
            : 'Show archived threads, notes and priorities',
        eventObject: EventObject.archived,
        eventAction: EventAction.viewed,
        icon: PlotIcon.archived,
      );

  factory ToggleArchivedVisibility({required BuildContext context}) {
    final showing = context.read<PriorityBloc>().state.showArchived;
    return ToggleArchivedVisibility._(showingArchived: showing);
  }

  final bool showingArchived;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleShowArchived();

    try {
      context.read<ThreadBloc>().toggleShowArchived();
    } on ProviderNotFoundException {
      // No thread open — nothing to toggle.
    }

    return const CommandDone();
  }
}

/// Toggle showing all priorities (active + archived) vs active only
class ToggleArchivedPrioritiesFilter extends Command {
  ToggleArchivedPrioritiesFilter({required this.showAllPriorities})
    : super(
        title: showAllPriorities
            ? 'Hide archived priorities'
            : 'Show archived priorities',
        subtitle: showAllPriorities
            ? 'Showing all priorities (active & archived)'
            : 'Showing active priorities only',
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
        icon: PlotIcon.archived,
      );

  final bool showAllPriorities;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<LocalPreferencesBloc>().toggleShowAllPriorities();
    return const CommandDone();
  }
}
