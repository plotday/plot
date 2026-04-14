import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/util/shortcut.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
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
    return CommandRoute(
      PriorityRoute(priorityIdString: priority!.id.toShortString()),
    );
  }
}

class OpenPlotApp extends Command {
  OpenPlotApp(this.priority)
    : super(
        title: 'Using Plot',
        subtitle: 'Updates, help, and your feedback',
        icon: PlotIcon.help,
        eventObject: EventObject.priority,
        eventAction: EventAction.viewed,
      );

  final Priority priority;

  @override
  bool get unread => priority.unread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandRoute(
      PriorityRoute(priorityIdString: priority.id.toShortString()),
    );
  }
}

class OpenTwistDev extends Command {
  OpenTwistDev(this.priority)
    : super(
        title: 'Twist Development',
        icon: PlotIcon.twist,
        eventObject: EventObject.priority,
        eventAction: EventAction.viewed,
      );

  final Priority priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandRoute(
      PriorityRoute(priorityIdString: priority.id.toShortString()),
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
    final filtered = Priority.excludePlot(priorities);
    final all = filtered.map((priority) => builder(priority)).toList();
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
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyJ),
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

  // Fetch user's teams for team selector
  List<Map<String, dynamic>> orgs = [];
  try {
    final orgList = await api.get<List<dynamic>>('/team');
    orgs = orgList.cast<Map<String, dynamic>>();
  } catch (_) {}

  // Determine initial team state from default parent
  final parentOrgId = defaultParent.teamId;
  final parentOrg = parentOrgId != null
      ? orgs.firstWhereOrNull(
          (o) => int.tryParse(o['id'] as String) == parentOrgId,
        )
      : null;

  final parentSelect = FormSelect<Priority>(
    key: 'parent',
    label: 'Parent',
    initialValue: defaultParent,
    items: (search) async => Priority.excludePlot(
      await Priority.get(order: PriorityOrder.nested, search: search),
    ),
    labelBuilder: (p) => PriorityLabel(priority: p),
    titleBuilder: (p) => p.ancestorsLabel() != null
        ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
        : p.title,
  );

  final teamSelect = orgs.isNotEmpty
      ? FormSelect<Map<String, dynamic>?>(
          key: 'team',
          label: 'Team',
          initialValue: parentOrg,
          hasInitialValue: true,
          readonlyMessage: parentOrg != null
              ? 'Team is inherited from parent priority'
              : null,
          items: (search) async =>
              <Map<String, dynamic>?>[null, ...orgs]
                  .where(
                    (o) =>
                        search == null ||
                        (o?['name']?.toString().toLowerCase() ??
                                'personal')
                            .contains(search.toLowerCase()),
                  )
                  .toList(),
          titleBuilder: (o) => o?['name'] as String? ?? 'Personal',
        )
      : null;

  // Update team field when parent selection changes
  if (teamSelect != null) {
    parentSelect.addListener(() {
      final selected = parentSelect.getValue();
      if (selected != null && selected.teamId != null) {
        final org = orgs.firstWhereOrNull(
          (o) =>
              int.tryParse(o['id'] as String) ==
              selected.teamId,
        );
        teamSelect.setValue(org);
        teamSelect.readonlyMessage =
            'Team is inherited from parent priority';
      } else {
        teamSelect.readonlyMessage = null;
      }
    });
  }

  return FormData(
    title: parent == null ? 'Add a priority' : 'Add a sub-priority',
    groups: [
      StaticFormGroup(
        items: [
          FormTextInput(
            key: 'title',
            label: 'Priority Name',
            required: true,
          ),
          parentSelect,
          if (teamSelect != null) teamSelect,
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
            buildCommand: (values) {
              final title = values['title'] as String;
              final selectedParent = values['parent'] as Priority;
              final color = values['color'] as ThemeColor?;
              final team = values['team'] as Map<String, dynamic>?;
              final priority = Priority(
                title: title,
                parent: selectedParent,
                color: color,
                draft: true,
              );
              // Parent's team takes precedence (constructor already
              // inherits teamId from parent)
              if (selectedParent.teamId != null) {
                return submitBuilder(Future.value(priority));
              }
              return submitBuilder(
                Future.value(
                  team != null
                      ? priority.copyWith(
                          teamId: Value(
                            int.parse(team['id'] as String),
                          ),
                        )
                      : priority,
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
        title: parent == null || (parent.root == true && parent.personal == true)
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
      submitBuilder: (priorityFuture) => _SaveAndReturnPriority(
        priorityFuture,
        onSaved: (p) => result = p,
      ),
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

          // Fetch user's teams for team selector
          List<Map<String, dynamic>> orgs = [];
          try {
            final orgList = await api.get<List<dynamic>>('/team');
            orgs = orgList.cast<Map<String, dynamic>>();
          } catch (_) {}

          // Determine team state — use parent's org as fallback for descendants
          // that haven't synced team_id yet
          final effectiveOrgId = p.teamId ?? parent?.teamId;
          final isTeamDescendant = effectiveOrgId != null && !p.root;
          final currentOrg = orgs.firstWhereOrNull(
            (o) => int.tryParse(o['id'] as String) == effectiveOrgId,
          );
          final isTeamAdmin = currentOrg?['role'] == 'admin';

          final parentSelect = FormSelect<Priority>(
            key: 'parent',
            label: 'Parent',
            initialValue: parent,
            enabled: !isRoot || p.teamId != null,
            placeholder: 'None',
            items: (search) async {
              final priorities = Priority.excludePlot(
                await Priority.get(order: PriorityOrder.nested, search: search),
              );
              return priorities.where((candidate) {
                if (candidate.id == p.id) return false;
                if (p.path.isParent(candidate.path)) return false;
                if (p.personal && !candidate.personal) return false;
                // Team roots can only be placed under personal priorities
                // or other priorities in the same team
                if (isRoot &&
                    p.teamId != null &&
                    !candidate.personal &&
                    candidate.teamId != effectiveOrgId) {
                  return false;
                }
                // Team descendants can only move within the same team
                if (isTeamDescendant &&
                    candidate.teamId != effectiveOrgId) {
                  return false;
                }
                return true;
              }).toList();
            },
            labelBuilder: (item) => PriorityLabel(priority: item),
            titleBuilder: (item) => item.ancestorsLabel() != null
                ? '${item.ancestorsLabel()}${Priority.separator}${item.title}'
                : item.title,
          );

          // Unified team selector — readonly for descendants, editable for
          // roots (admin only when already in a team)
          final showTeamSelect = orgs.isNotEmpty || currentOrg != null;
          final teamSelect = showTeamSelect
              ? FormSelect<Map<String, dynamic>?>(
                  key: 'team',
                  label: 'Team',
                  initialValue: currentOrg,
                  hasInitialValue: true,
                  readonlyMessage: isTeamDescendant
                      ? 'Team is inherited from parent priority'
                      : null,
                  enabled:
                      isTeamDescendant ||
                      p.teamId == null ||
                      isTeamAdmin,
                  items: (search) async =>
                      <Map<String, dynamic>?>[null, ...orgs]
                          .where(
                            (o) =>
                                search == null ||
                                (o?['name']?.toString().toLowerCase() ??
                                        'personal')
                                    .contains(search.toLowerCase()),
                          )
                          .toList(),
                  titleBuilder: (o) => o?['name'] as String? ?? 'Personal',
                )
              : null;

          // Update team field when parent selection changes
          if (teamSelect != null) {
            parentSelect.addListener(() {
              final newParent = parentSelect.getValue();
              if (newParent != null && newParent.teamId != null) {
                final org = orgs.firstWhereOrNull(
                  (o) =>
                      int.tryParse(o['id'] as String) ==
                      newParent.teamId,
                );
                teamSelect.setValue(org);
                teamSelect.readonlyMessage =
                    'Team is inherited from parent priority';
              } else if (isTeamAdmin || effectiveOrgId == null) {
                teamSelect.readonlyMessage = null;
              }
            });
          }

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
                  if (teamSelect != null) teamSelect,
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
                  FormButton(
                    key: 'save',
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      final newParent = values['parent'] as Priority?;
                      final color = values['color'] as ThemeColor?;
                      final team = values['team'] as Map<String, dynamic>?;
                      // Parent's team takes precedence
                      Value<int?> orgId;
                      if (newParent?.teamId != null) {
                        orgId = Value(newParent!.teamId);
                      } else if (showTeamSelect) {
                        orgId = team != null
                            ? Value(int.parse(team['id'] as String))
                            : const Value(null);
                      } else {
                        orgId = const Value.absent();
                      }
                      return EditPriority(
                        Future.value(
                          p.copyWith(
                            title: title,
                            parent: newParent,
                            color: Value(color),
                            teamId: orgId,
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
  if (!(priority.root && priority.personal))
    SetTopPriority(priority, priority.topOrder == null),
  if (!priority.isViewer) NewPriority(parent: priority),
  if (!(priority.root && priority.personal) && !priority.isViewer &&
      !priority.isPlot)
    TogglePriorityArchived(priority),
];

List<Command> priorityCommands(Priority priority) => [
  ...prioritySecondaryCommands(priority),
];

List<Command> currentPriorityCommands(Priority priority) => [
  ...prioritySecondaryCommands(priority),
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

List<StaticCommandGroup> currentPriorityCommandGroups(Priority priority) => [
  StaticCommandGroup(
    title: 'Priority: ${priority.title}',
    commands: currentPriorityCommands(priority),
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
        on: showAllPriorities, // Highlighted when showing all
      );

  final bool showAllPriorities;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<LocalPreferencesBloc>().toggleShowAllPriorities();
    return const CommandDone();
  }
}
