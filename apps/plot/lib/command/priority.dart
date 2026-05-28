import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'command.dart';
import 'package:plot/util/priority_nav.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/priorities_shell.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/widget/time_tracking_modal.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/api/upgrade_api.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
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
  ChangeCurrentPriority(
    Priority super.priority, {
    super.ancestry = true,
    this.fromAgenda = false,
  }) : super(
         eventObject: EventObject.priority,
         eventAction: EventAction.viewed,
       );

  /// When true, mark the next [PriorityBloc] construction / [setPriority]
  /// call so the destination page opens with descendants hidden — agenda
  /// navigation already surfaces sub-priority content under each block's
  /// header, so the feed defaults to direct threads only.
  final bool fromAgenda;

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
    if (fromAgenda) {
      PriorityBloc.markNextPriorityFromAgenda();
    }

    final tabsRouter = _tabsRouterOrNull(context);
    PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
      activeTabIndex: tabsRouter?.activeIndex,
      currentSourceTab: PrioritiesShell.sourceTab,
    );

    final targetPriorityIdString = priority!.id.toShortString();
    // `context` here is the CommandModal's rootContext, which can be the
    // global CommandScope from GlobalShortcuts — that scope sits above
    // LayoutStateProvider, so `read<LayoutBloc>()` throws. `isMultiPanel`
    // does a nullable read and falls back to MediaQuery.
    final multi = context.isMultiPanel;

    // Same-priority fast path: when the priority the user tapped is
    // already on the Activity tab's stack, `root.navigate(PriorityRoute(
    // X, children: null))` does something destructive to the inner
    // [PriorityOnlyRoute] (drops it without remounting) and produces
    // a forever-spinner. Skip the navigate, switch tabs explicitly,
    // and force-refresh the inner route so Android's predictive-back
    // dispatcher re-registers PopScope on the active page.
    if (isSamePriorityAtActivityTop(
      tabsRouter: tabsRouter,
      targetPriorityIdString: targetPriorityIdString,
      priorityRouteName: PriorityRoute.name,
    )) {
      if (tabsRouter!.activeIndex != PriorityTabs.activity) {
        tabsRouter.setActiveIndex(PriorityTabs.activity);
      }
      final innerRouter = findPriorityInnerRouter(
        context.router.root,
        PriorityRoute.name,
      );
      if (innerRouter != null) {
        innerRouter.replaceAll([
          multi ? NewThreadRoute() : PriorityOnlyRoute(),
        ]);
      }
      return const CommandDone();
    }

    // Mark for URL-history replace when this is an in-tab navigation
    // (priority-to-priority while already on the Activity tab) so the
    // browser/Cmd+[ history doesn't accumulate one entry per priority
    // the user paged through. Cross-tab arrivals (Priorities/Agenda →
    // Activity) push so back walks back to the originating tab.
    if (isOnActivityTab(tabsRouter)) {
      context.router.root.navigationHistory.markUrlStateForReplace();
    }

    // In multi-panel mode the right panel should land on NewThreadPage for
    // the new priority. Passing it as a child here drives AutoRoute to
    // reconcile the inner stack to [NewThreadRoute] without going through
    // the PriorityOnlyPage→LoadingPage redirect that used to flash.
    return CommandRoute(
      PriorityRoute(
        priorityIdString: targetPriorityIdString,
        children: multi ? [NewThreadRoute()] : null,
      ),
    );
  }
}

/// Returns the [AutoTabsRouter] for [PrioritiesShell] if visible from
/// [context]. Returns null when out of scope (e.g. command triggered
/// from a modal outside the shell tree) so callers can fall back
/// gracefully.
TabsRouter? _tabsRouterOrNull(BuildContext context) {
  try {
    return AutoTabsRouter.of(context);
  } catch (_) {
    return null;
  }
}

class PriorityGroup extends CommandGroup {
  PriorityGroup({required super.title, required this.builder});

  final Command Function(Priority? priority) builder;

  @override
  Future<List<Command>> list({String? search}) async {
    final priorities = await Priority.get(order: PriorityOrder.recent);
    final filtered = search == null || search.isEmpty
        ? priorities
        : priorities.where((p) => p.matchesSearch(search)).toList();
    return filtered.map((priority) => builder(priority)).toList();
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
    final targetPriorityIdString = priorityId.toShortString();
    final multi = context.isMultiPanel;
    final tabsRouter = _tabsRouterOrNull(context);
    PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
      activeTabIndex: tabsRouter?.activeIndex,
      currentSourceTab: PrioritiesShell.sourceTab,
    );
    // Same-priority fast path — see [ChangeCurrentPriority.run].
    if (isSamePriorityAtActivityTop(
      tabsRouter: tabsRouter,
      targetPriorityIdString: targetPriorityIdString,
      priorityRouteName: PriorityRoute.name,
    )) {
      if (tabsRouter!.activeIndex != PriorityTabs.activity) {
        tabsRouter.setActiveIndex(PriorityTabs.activity);
      }
      final innerRouter = findPriorityInnerRouter(
        context.router.root,
        PriorityRoute.name,
      );
      if (innerRouter != null) {
        innerRouter.replaceAll([
          multi ? NewThreadRoute() : PriorityOnlyRoute(),
        ]);
      }
      return const CommandDone();
    }
    if (isOnActivityTab(tabsRouter)) {
      context.router.root.navigationHistory.markUrlStateForReplace();
    }
    return CommandRoute(
      PriorityRoute(
        priorityIdString: targetPriorityIdString,
        children: multi ? [NewThreadRoute()] : null,
      ),
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
    final multi = context.mounted ? context.isMultiPanel : false;
    if (context.mounted) {
      final tabsRouter = _tabsRouterOrNull(context);
      PrioritiesShell.sourceTab = computeSourceTabAfterPriorityTap(
        activeTabIndex: tabsRouter?.activeIndex,
        currentSourceTab: PrioritiesShell.sourceTab,
      );
    }
    return CommandRoute(
      PriorityRoute(
        priorityIdString: savedPriority.id.toShortString(),
        children: multi ? [NewThreadRoute()] : null,
      ),
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

    // When unarchiving, or when the priority has no team, use the normal flow.
    if (isArchived || priority.teamId == null) {
      await priority
          .copyWith(archivedAt: Value(isArchived ? null : DateTime.now()))
          .save();
      return const CommandDone();
    }

    // Check whether this is the last top-level team priority. If not, archive
    // normally. If yes, route through the "leave team" confirmation flow.
    final otherCount = await Priority.countOtherTopLevelTeamPriorities(
      teamId: priority.teamId!,
      excludeId: priority.id,
    );

    if (otherCount > 0) {
      // Not the last — archive normally.
      await priority.copyWith(archivedAt: Value(DateTime.now())).save();
      return const CommandDone();
    }

    // This is the last top-level team priority — look up the team name and ask
    // the user if they want to leave the team.
    String teamName = 'this team';
    try {
      final usage = await UpgradeApi.getUsage();
      final teamIdStr = priority.teamId!.toString();
      final team = usage.teams.where((t) => t.id == teamIdStr).firstOrNull;
      if (team != null) teamName = team.name;
    } catch (_) {
      // Non-critical — fall back to generic name.
    }

    if (!context.mounted) return const CommandSkipped();
    final confirmed = await ConfirmModal(
      title: 'Leave team',
      message: 'Are you sure you want to leave the team $teamName?',
      confirmLabel: 'Leave team',
      cancelLabel: 'Cancel',
      destructive: true,
    ).run(context);
    if (!confirmed) return const CommandSkipped();

    // POST to the archive-or-leave endpoint and handle responses.
    try {
      final result = await api.post<Map<String, dynamic>>(
        '/sync/priority/archive-or-leave',
        body: {'priority_id': priority.id.toString()},
      );
      final status = result['status'] as String?;
      if (status == 'archived' || status == 'left_team') {
        // Locally archive the priority so the UI updates immediately; the
        // server will also deliver the change on the next sync tick.
        await priority.copyWith(archivedAt: Value(DateTime.now())).save();
      }
      return const CommandDone();
    } on ApiException catch (e) {
      if (e.statusCode == 409 && e.description == 'last_admin') {
        if (!context.mounted) return const CommandSkipped();
        await ConfirmModal(
          title: 'Last admin',
          message:
              "You're the last admin of $teamName. Promote another admin first.",
          confirmLabel: 'OK',
          cancelLabel: 'Dismiss',
        ).run(context);
        return const CommandSkipped();
      }
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException {
      return const CommandMessage(
        "You're offline. Please try again when connected.",
        isError: true,
      );
    }
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
  final fallbackParent =
      parent ??
      currentPriority ??
      prioritiesBloc.state.root ??
      await Priority.getDefault();
  final defaultParent = fallbackParent.isPlot
      ? (prioritiesBloc.state.root ?? await Priority.getDefault())
      : fallbackParent;

  // Fetch team list for the team selector (only relevant for top-level
  // priorities whose parent is the root). Ignore errors — teams list is
  // optional and falls back to an empty list if unavailable.
  final isTopLevel = defaultParent.root;
  List<TeamUsage> teams = const [];
  if (isTopLevel) {
    try {
      final usage = await UpgradeApi.getUsage();
      teams = usage.teams;
    } catch (_) {
      // Non-critical — proceed without team options
    }
  }

  final parentSelect = FormSelect<Priority>(
    key: 'parent',
    label: 'Parent',
    initialValue: defaultParent,
    items: (search) async {
      final priorities = await Priority.get(order: PriorityOrder.nested);
      return priorities.where((p) {
        if (p.isPlot) return false;
        if (search == null || search.isEmpty) return true;
        return p.matchesSearch(search);
      }).toList();
    },
    labelBuilder: (p) => PriorityLabel(priority: p),
    titleBuilder: (p) => p.ancestorsLabel() != null
        ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
        : p.title,
  );

  // Team selector: only shown when creating a top-level priority and the user
  // belongs to at least one team. "Personal" maps to null (no team).
  final teamSelect = isTopLevel && teams.isNotEmpty
      ? FormSelect<TeamUsage?>(
          key: 'team',
          label: 'Team',
          initialValue: null,
          hasInitialValue: true,
          items: (search) async {
            final all = [null, ...teams];
            if (search == null || search.isEmpty) return all;
            final lower = search.toLowerCase();
            return all
                .where(
                  (t) => t == null || t.name.toLowerCase().startsWith(lower),
                )
                .toList();
          },
          titleBuilder: (t) => t?.name ?? 'Personal',
        )
      : null;

  return FormData(
    title: parent == null ? 'Add a priority' : 'Add a sub-priority',
    groups: [
      StaticFormGroup(
        items: [
          FormTextInput(key: 'title', label: 'Priority Name', required: true),
          parentSelect,
          ?teamSelect,
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
              final selectedTeam = values['team'] as TeamUsage?;
              final teamId = selectedTeam != null
                  ? BigInt.parse(selectedTeam.id)
                  : null;
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
                    teamId: teamId,
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

          // A top-level priority is one whose parent is the root priority and
          // is not the root itself.
          final isTopLevel = !isRoot && (parent?.root ?? false);

          // Fetch team list for the team selector when editing a top-level
          // priority with no team set yet (lock-once-set: once a team is
          // chosen the selector becomes read-only).
          List<TeamUsage> teams = const [];
          if (isTopLevel && p.teamId == null) {
            try {
              final usage = await UpgradeApi.getUsage();
              teams = usage.teams;
            } catch (_) {
              // Non-critical — proceed without team options
            }
          }

          // Resolve current team name for the read-only badge when team is set.
          String? currentTeamName;
          if (isTopLevel && p.teamId != null) {
            try {
              final usage = await UpgradeApi.getUsage();
              final teamIdStr = p.teamId!.toString();
              currentTeamName = usage.teams
                  .firstWhere(
                    (t) => t.id == teamIdStr,
                    orElse: () => TeamUsage(
                      id: teamIdStr,
                      name: 'Team',
                      connections: const ResourceUsage(count: 0),
                      isAdmin: false,
                    ),
                  )
                  .name;
            } catch (_) {
              currentTeamName = 'Team';
            }
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
              );
              return priorities.where((candidate) {
                if (candidate.id == p.id) return false;
                if (p.path.isParent(candidate.path)) return false;
                if (candidate.isPlot) return false;
                if (search != null &&
                    search.isNotEmpty &&
                    !candidate.matchesSearch(search)) {
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

          // Team selector for top-level priorities:
          // - If team_id is already set: read-only (show team name, no editing)
          // - If team_id is null and user is in teams: editable selector
          // - Otherwise: not shown
          FormSelect<TeamUsage?>? teamSelect;
          if (isTopLevel && p.teamId != null) {
            // Read-only: lock-once-set — display current team, disallow change
            teamSelect = FormSelect<TeamUsage?>(
              key: 'team',
              label: 'Team',
              initialValue: currentTeamName != null
                  ? TeamUsage(
                      id: p.teamId!.toString(),
                      name: currentTeamName,
                      connections: const ResourceUsage(count: 0),
                      isAdmin: false,
                    )
                  : null,
              hasInitialValue: true,
              enabled: false,
              readonlyMessage: 'Team cannot be changed after it is set.',
              items: (search) async => [],
              titleBuilder: (t) => t?.name ?? 'Personal',
            );
          } else if (isTopLevel && teams.isNotEmpty) {
            // Editable: allow null→team promotion
            teamSelect = FormSelect<TeamUsage?>(
              key: 'team',
              label: 'Team',
              initialValue: null,
              hasInitialValue: true,
              items: (search) async {
                final all = [null, ...teams];
                if (search == null || search.isEmpty) return all;
                final lower = search.toLowerCase();
                return all
                    .where(
                      (t) =>
                          t == null || t.name.toLowerCase().startsWith(lower),
                    )
                    .toList();
              },
              titleBuilder: (t) => t?.name ?? 'Personal',
            );
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
                  ?teamSelect,
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
                  if (!p.isPlot)
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
                      final shared = values['shared'] as SharedSelection?;
                      // Team: only update when editable (team was null before).
                      // Otherwise leave the existing team_id alone — locked
                      // once set, and only the top-level row carries it.
                      final Value<BigInt?> newTeamId;
                      if (isTopLevel && p.teamId == null) {
                        final selectedTeam = values['team'] as TeamUsage?;
                        newTeamId = Value(
                          selectedTeam != null
                              ? BigInt.parse(selectedTeam.id)
                              : null,
                        );
                      } else {
                        newTeamId = const Value.absent();
                      }
                      // When the shared form field isn't rendered (e.g.
                      // on the Plot system priority), leave the existing
                      // contacts/groups/invites alone instead of clearing
                      // them.
                      return EditPriority(
                        Future.value(
                          shared == null
                              ? p.copyWith(
                                  title: title,
                                  parent: newParent,
                                  color: Value(color),
                                  teamId: newTeamId,
                                )
                              : p.copyWith(
                                  title: title,
                                  parent: newParent,
                                  color: Value(color),
                                  teamId: newTeamId,
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
        title: 'More',
        icon: PlotIcon.menu,
        commands: Commands(
          groups: current
              ? currentPriorityCommandGroups(priority)
              : priorityCommandGroups(priority),
        ),
      );
}

List<Command> prioritySecondaryCommands(Priority priority) => [
  if (!priority.isViewer) EditPriorityCommand(priority),
  if (!priority.isViewer) ShowResponseTimesSettings(priority),
  if (!priority.root) SetTopPriority(priority, priority.topOrder == null),
  if (!priority.isViewer && !priority.isPlot) NewPriority(parent: priority),
  ShowTimeLog(priority),
  if (!priority.root && !priority.isViewer && !priority.isPlot)
    TogglePriorityArchived(priority),
];

List<Command> priorityCommands(Priority priority) => [
  ...prioritySecondaryCommands(priority),
];

List<Command> currentPriorityCommands(
  Priority priority, {
  BuildContext? context,
  NowState? nowState,
}) => [
  ...prioritySecondaryCommands(priority),
  if (context != null) ToggleArchivedVisibility(context: context),
  // Broom filter: show only muted threads so users can find the rules
  // they've set and un-mute. Available in both regular and archived views
  // since the filter applies to mute_by_thread_id across all threads.
  if (context != null) ToggleMuteFilter(context: context),
  NewThread(),
  OpenNextThread(),
  OpenPreviousThread(),
  if (nowState != null) ...timerCommands(nowState),
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
  NowState? nowState,
}) => [
  StaticCommandGroup(
    title: 'Priority: ${priority.title}',
    commands: currentPriorityCommands(
      priority,
      context: context,
      nowState: nowState,
    ),
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

/// Toggle the broom "Muted only" filter on the unified feed. When on,
/// the activity feed is restricted to threads carrying a
/// `mute_by_thread_id` flag — the ones a "Skip active for threads like
/// this" rule swept. Surfaced as a filter chip so users can find and
/// toggle existing rules from anywhere in the feed.
class ToggleMuteFilter extends Command {
  ToggleMuteFilter._({required this.showingMuteOnly})
    : super(
        title: showingMuteOnly ? 'Show all' : 'Show muted only',
        subtitle: showingMuteOnly
            ? 'Show every thread in this feed'
            : 'Show only threads filed under a mute rule',
        eventObject: EventObject.activity,
        eventAction: EventAction.filtered,
        icon: PlotIcon.broom,
      );

  factory ToggleMuteFilter({required BuildContext context}) {
    final state = context.read<PriorityBloc>().state;
    return ToggleMuteFilter._(showingMuteOnly: state.muteOnly);
  }

  final bool showingMuteOnly;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleMuteOnly();
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

/// Toggle whether the activity feed and todo list on the priority page
/// roll up threads from descendant priorities, or show only threads filed
/// directly under the current priority.
///
/// Selected (on) state = "hide sub-priorities" = the long-standing rollup
/// behaviour (descendant threads are visible inline). Off = only direct
/// threads, so sub-priorities surface as their own pages instead.
class ToggleHideSubPriorities extends Command {
  ToggleHideSubPriorities._({required this.hidingSubPriorities})
    : super(
        title: hidingSubPriorities
            ? 'Hide sub-priorities'
            : 'Show sub-priorities',
        subtitle: hidingSubPriorities
            ? 'Rolling up threads from sub-priorities into this view'
            : 'Showing only threads filed directly on this priority',
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
        // Mirror the PrioritiesList caret semantics: chevronDown when the
        // sub-priority *content* is visible inline (the long-standing
        // rollup behaviour where descendant threads expand into this
        // feed), chevronRight when that content is collapsed away
        // (direct-only feed; sub-priorities are reached as their own
        // pages instead).
        icon: hidingSubPriorities
            ? FontAwesomeIcons.chevronDown
            : FontAwesomeIcons.chevronRight,
      );

  factory ToggleHideSubPriorities({required BuildContext context}) {
    final hiding = context.read<PriorityBloc>().state.hideSubPriorities;
    return ToggleHideSubPriorities._(hidingSubPriorities: hiding);
  }

  final bool hidingSubPriorities;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleHideSubPriorities();
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

/// Open the [TimeTrackingModal] for a priority so users can review and
/// adjust recorded time. Surfaced from the priority's More modal.
class ShowTimeLog extends Command {
  ShowTimeLog(this.priority)
    : super(
        title: 'Time log',
        icon: PlotIcon.stopwatch,
        eventObject: EventObject.priority,
        eventAction: EventAction.viewed,
      );

  final Priority priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await TimeTrackingModal(priority: priority).show<void>(context);
    return const CommandDone();
  }
}

/// Writes the global tracking-pause flag on user_settings. When paused,
/// the [NowBloc] driver does not extend [Session.resume] and the server's
/// event finalizer skips occurrences whose end falls inside the paused
/// window. [paused] = true pauses; false clears the timestamp.
Future<void> _setTrackingPaused({required bool paused}) async {
  final existing = await UserSettingsEntity.get();
  final companion = UserSettingsCompanion(
    // Sentinel epoch tells the server "explicit clear"; locally the
    // [LocalDateTimeConverter] just stores it. On the next push we
    // pass tracking_paused_at as is and the server's CASE handles it.
    trackingPausedAt: Value(
      paused
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    ),
    // Preserve other fields if a row already exists.
    enterBehavior: existing?.enterBehavior == null
        ? const Value.absent()
        : Value(existing!.enterBehavior),
    aiEnabled: existing?.aiEnabled == null
        ? const Value.absent()
        : Value(existing!.aiEnabled),
    onboardingCompleted: existing?.onboardingCompleted == null
        ? const Value.absent()
        : Value(existing!.onboardingCompleted),
  );
  await UserSettingsEntity.save(companion);
}

/// Pause time tracking globally. Surfaced from the priority header pill
/// when a session is active.
class PauseTracking extends Command {
  PauseTracking()
    : super(
        title: 'Pause',
        icon: FontAwesomeIcons.pause,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await _setTrackingPaused(paused: true);
    return const CommandDone();
  }
}

/// Resume time tracking globally. Surfaced from the priority header pill
/// when tracking is paused — phrased "Log time" to express the user-facing
/// effect of starting to accumulate time again.
class ResumeTracking extends Command {
  ResumeTracking()
    : super(
        title: 'Log time',
        icon: FontAwesomeIcons.play,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await _setTrackingPaused(paused: false);
    return const CommandDone();
  }
}
