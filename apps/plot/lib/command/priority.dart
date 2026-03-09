import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'command.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/util/shortcut.dart';
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/util/theme_color.dart';

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

class OpenGettingStarted extends Command {
  OpenGettingStarted(this.priority)
    : super(
        title: 'Getting started',
        icon: PlotIcon.gettingStarted,
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

class OpenHelpFeedback extends Command {
  OpenHelpFeedback(this.priority)
    : super(
        title: 'Help + feedback',
        icon: PlotIcon.help,
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
  ChangeCurrentPriorityCommands({
    super.prompt = 'Change Current Priority',
    Priority? initialPriority,
  }) : super(
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
        .copyWith(
          archivedAt: Value(isArchived ? null : DateTime.now()),
        )
        .save();
    return const CommandDone();
  }
}

class NewPriority extends ShowForm {
  NewPriority({Priority? parent})
    : super(
        title: parent == null || parent.root == true
            ? 'Add a priority'
            : 'Add a sub-priority',
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
            title: parent == null ? 'Add a priority' : 'Add a sub-priority',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Priority Name',
                    required: true,
                  ),
                  FormSelect<Priority>(
                    key: 'parent',
                    label: 'Parent',
                    initialValue: defaultParent,
                    items: (search) async => Priority.excludePlot(
                      await Priority.get(
                        order: PriorityOrder.nested,
                        search: search,
                      ),
                    ),
                    labelBuilder: (p) => PriorityLabel(priority: p),
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
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      final selectedParent = values['parent'] as Priority;
                      final color = values['color'] as ThemeColor?;
                      return AddPriority(
                        Future.value(
                          Priority(
                            title: title,
                            parent: selectedParent,
                            color: color,
                            draft: true,
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

class EditPriorityCommand extends ShowForm {
  EditPriorityCommand(Priority priority)
    : super(
        title: 'Edit priority',
        icon: PlotIcon.settings,
        form: (context) async {
          final isRoot = priority.root;
          // Load parent if not already loaded (parent might be null even when priority has ancestors)
          Priority? parent = priority.parent;
          if (parent == null && priority.parentId != null) {
            parent = await Priority.getOne(priority.parentId!);
          }

          return FormData(
            title: 'Edit priority',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Priority Name',
                    initialValue: priority.title,
                    required: true,
                  ),
                  FormSelect<Priority>(
                    key: 'parent',
                    label: 'Parent',
                    initialValue: parent,
                    enabled: !isRoot,
                    placeholder: 'None',
                    items: (search) async {
                      final priorities = Priority.excludePlot(
                        await Priority.get(
                          order: PriorityOrder.nested,
                          search: search,
                        ),
                      );
                      return priorities.where((p) {
                        if (p.id == priority.id) return false;
                        if (priority.path.isParent(p.path)) return false;
                        if (priority.personal && !p.personal) return false;
                        return true;
                      }).toList();
                    },
                    labelBuilder: (p) => PriorityLabel(priority: p),
                    titleBuilder: (p) => p.ancestorsLabel() != null
                        ? '${p.ancestorsLabel()}${Priority.separator}${p.title}'
                        : p.title,
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
                    buildCommand: (values) {
                      final title = values['title'] as String;
                      final newParent = values['parent'] as Priority?;
                      final color = values['color'] as ThemeColor?;
                      return EditPriority(
                        Future.value(
                          priority.copyWith(
                            title: title,
                            parent: newParent,
                            color: Value(color),
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
          prompt: priority.title,
        ),
      );
}

List<Command> prioritySecondaryCommands(Priority priority) => [
  EditPriorityCommand(priority),
  if (!priority.root) ManagePrioritySharing(priority),
  if (!priority.root) SetTopPriority(priority, priority.topOrder == null),
  NewPriority(parent: priority),
  if (!priority.root) TogglePriorityArchived(priority),
];

List<Command> priorityCommands(Priority priority) => [
  OpenPriority(priority),
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

class SharePriority extends PriorityCommand {
  SharePriority(Priority super.priority, this.contactId, {required this.add})
    : super(
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final Uuid contactId;
  final bool add;

  @override
  String get title => add ? 'Share' : 'Unshare';

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/priority/${priority!.id}/share',
        body: {
          'add': add ? [contactId.toString()] : <String>[],
          'remove': add ? <String>[] : [contactId.toString()],
        },
      );
      // Ignore response - sync will update local state
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

/// Command to manage sharing for a priority.
/// Shows three sections: Members (accepted users), Invited (pending invitations), and Share (available contacts).
class ManagePrioritySharing extends ShowCommands {
  ManagePrioritySharing(this.priority)
    : super(
        title: priority.sharing ? 'Manage sharing' : 'Share priority',
        icon: priority.sharing ? PlotIcon.shared : PlotIcon.share,
        commandsBuilder: (context) => _getSharingCommands(priority),
      );

  final Priority priority;

  static Future<Commands> _getSharingCommands(Priority priority) async {
    // Fetch all actors for initial ContactGroup cache
    final allActors = await Actor.get(
      types: [ActorType.user, ActorType.contact],
      limit: 100,
    );

    // For descendants, use the shared ancestor as the source for members
    final sourcePriority = priority.sharingAncestorId != null
        ? await Priority.getOne(priority.sharingAncestorId!)
        : priority;

    final groups = <CommandGroup>[
      AcceptedMembersGroup(title: 'Members', priority: sourcePriority),
      InvitedMembersGroup(title: 'Invited', priority: sourcePriority),
      ContactGroup(
        title: 'Share',
        priority: sourcePriority,
        excludeActorIds: {},
        initialActors: allActors,
      ),
    ];

    return Commands(
      prompt: 'Share with',
      emptyMessage: 'Enter an email address to invite someone else',
      groups: groups,
    );
  }
}

/// A CommandGroup for searchable contacts with email invite support.
class ContactGroup extends CommandGroup {
  ContactGroup({
    required super.title,
    required this.priority,
    required this.excludeActorIds,
    this.initialActors = const [],
  });

  final Priority priority;
  final Set<Uuid> excludeActorIds;
  final List<Actor> initialActors;

  @override
  Future<List<Command>> list({String? search}) async {
    List<Actor> actors;

    if (search == null || search.isEmpty) {
      actors = initialActors;
    } else {
      actors = await Actor.get(
        types: [ActorType.user, ActorType.contact],
        search: search,
        limit: 50,
      );
    }

    // Dynamically fetch exclude set from priority members (both accepted and invited)
    final members = await PriorityMember.getForPriority(priority.id);

    // Build exclude set from member contact_ids (already ActorId)
    final excludeActorIds = members.map((m) => m.contactId).toSet();

    // Filter out excluded and self
    final filteredActors = actors
        .where((a) => !excludeActorIds.contains(a.id) && !a.self)
        .toList();

    final commands = <Command>[
      ...filteredActors.map((actor) => InviteContact(priority, actor)),
    ];

    // If search looks like an email and no exact match exists, add "invite by email" option
    if (search != null && _isValidEmail(search)) {
      final emailExists = actors.any(
        (a) => a.email?.toLowerCase() == search.toLowerCase(),
      );
      if (!emailExists) {
        commands.insert(0, InviteByEmail(priority, search));
      }
    }

    return commands;
  }

  static bool _isValidEmail(String value) {
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);
  }
}

class AcceptedMembersGroup extends CommandGroup {
  AcceptedMembersGroup({required super.title, required this.priority});

  final Priority priority;

  @override
  Future<List<Command>> list({String? search}) async {
    // Get only accepted members
    final members = await PriorityMember.getAcceptedForPriority(priority.id);

    final commands = <Command>[];
    for (final member in members) {
      // Get actor by contact_id (no remote lookup needed!)
      final actor = await Actor.getOne(member.contactId);

      // Filter by search
      if (search != null && search.isNotEmpty) {
        final searchLower = search.toLowerCase();
        final nameMatch =
            actor.name?.toLowerCase().contains(searchLower) ?? false;
        final emailMatch =
            actor.email?.toLowerCase().contains(searchLower) ?? false;
        if (!nameMatch && !emailMatch) {
          continue;
        }
      }

      // Show current user with special command
      if (actor.self) {
        commands.add(CurrentUserMemberCommand(priority, actor));
        continue;
      }

      // All members in this group are accepted
      commands.add(EditSharingCommand(priority, actor));
    }

    return commands;
  }
}

class InvitedMembersGroup extends CommandGroup {
  InvitedMembersGroup({required super.title, required this.priority});

  final Priority priority;

  @override
  Future<List<Command>> list({String? search}) async {
    // Get only invited members
    final members = await PriorityMember.getInvitedForPriority(priority.id);

    final commands = <Command>[];
    for (final member in members) {
      // Get actor by contact_id (no remote lookup needed!)
      final actor = await Actor.getOne(member.contactId);

      // Skip current user - shouldn't be in invited list anyway
      if (actor.self) continue;

      // Filter by search
      if (search != null && search.isNotEmpty) {
        final searchLower = search.toLowerCase();
        final nameMatch =
            actor.name?.toLowerCase().contains(searchLower) ?? false;
        final emailMatch =
            actor.email?.toLowerCase().contains(searchLower) ?? false;
        if (!nameMatch && !emailMatch) {
          continue;
        }
      }

      // Look up inviter name for subtitle
      String? inviterName;
      if (member.invitedBy != null) {
        if (member.invitedBy == Base.userId) {
          inviterName = 'you';
        } else {
          final inviter = await Actor.getByUserId(member.invitedBy!);
          inviterName = inviter?.nameOrEmail;
        }
      }
      commands.add(EditInvitationCommand(priority, actor, inviterName));
    }

    return commands;
  }
}

/// View/manage an existing shared user - opens a form with remove option.
class EditSharingCommand extends ShowForm {
  EditSharingCommand(this.priority, this.actor)
    : super(
        title: actor.nameOrEmail,
        subtitle: actor.name != null ? actor.email : null,
        icon: PlotIcon.user,
        form: (context) => _buildForm(priority, actor),
      );

  final Priority priority;
  final Actor actor;

  static Future<FormData> _buildForm(Priority priority, Actor actor) async {
    return FormData(
      title: actor.nameOrEmail,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text: '${actor.nameOrEmail} has access to ${priority.title}.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'remove',
              buildCommand: (_) => _RemoveSharingCommand(priority, actor),
            ),
          ],
        ),
      ],
    );
  }
}

class _RemoveSharingCommand extends Command {
  _RemoveSharingCommand(this.priority, this.actor)
    : super(
        title: 'Remove from ${priority.title}',
        icon: FontAwesomeIcons.trash,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final Priority priority;
  final Actor actor;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await SharePriority(
      priority,
      actor.id.toUuid(),
      add: false,
    ).run(context);
    if (result is CommandDone) {
      // Pull sync data so the local database is updated before refresh
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityMember);

      return CommandRefresh(message: 'Access removed for ${actor.nameOrEmail}');
    }
    return result;
  }
}

/// Show current user's membership with option to leave priority.
class CurrentUserMemberCommand extends Command {
  CurrentUserMemberCommand(this.priority, this.actor)
    : super(
        title: 'You',
        subtitle: actor.email ?? actor.name,
        icon: PlotIcon.user,
        eventObject: EventObject.priority,
        eventAction: EventAction.viewed,
      );

  final Priority priority;
  final Actor actor;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Show details with Leave Priority option
    return ShowCommands(
      title: 'You',
      icon: PlotIcon.user,
      commands: Commands(
        groups: [
          StaticCommandGroup(commands: [LeavePriorityCommand(priority)]),
        ],
      ),
    ).run(context);
  }
}

/// Leave priority command - allows user to remove their own access.
class LeavePriorityCommand extends Command {
  LeavePriorityCommand(this.priority)
    : super(
        title: 'Leave priority',
        subtitle: 'Remove your access to this priority',
        icon: PlotIcon.signOut,
        eventObject: EventObject.priority,
        eventAction: EventAction.deleted,
      );

  final Priority priority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Check if user is the only member
    final members = await PriorityMember.getAcceptedForPriority(priority.id);
    if (members.length <= 1) {
      return const CommandMessage(
        'Cannot leave priority - you are the only member',
        isError: true,
      );
    }

    // Get current user's actor
    final currentUser = await Actor.getOne(Base.actorId);

    if (!context.mounted) {
      return const CommandSkipped();
    }

    final result = await SharePriority(
      priority,
      currentUser.id.toUuid(),
      add: false,
    ).run(context);

    if (result is CommandDone) {
      // Pull priority_member to reflect removal
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityMember);

      return CommandRefresh(message: 'Left priority');
    }
    return result;
  }
}

/// View/manage a pending invitation - opens a form with cancel option.
class EditInvitationCommand extends ShowForm {
  EditInvitationCommand(this.priority, this.actor, String? inviterName)
    : super(
        title: actor.nameOrEmail,
        subtitle: _buildSubtitle(actor, inviterName),
        icon: PlotIcon.waiting,
        form: (context) => _buildForm(priority, actor),
      );

  static String? _buildSubtitle(Actor actor, String? inviterName) {
    final parts = <String>[];
    // Only show email in subtitle if name is available (to avoid repeating email)
    if (actor.name != null) parts.add(actor.email ?? '');
    if (inviterName != null) parts.add('invited by $inviterName');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  final Priority priority;
  final Actor actor;

  static Future<FormData> _buildForm(Priority priority, Actor actor) async {
    return FormData(
      title: actor.nameOrEmail,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text: 'Invitation pending for ${actor.nameOrEmail} to ${priority.title}.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'cancel',
              buildCommand: (_) => _CancelInvitationCommand(priority, actor),
            ),
          ],
        ),
      ],
    );
  }
}

class _CancelInvitationCommand extends Command {
  _CancelInvitationCommand(this.priority, this.actor)
    : super(
        title: 'Cancel invitation to ${priority.title}',
        icon: FontAwesomeIcons.trash,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final Priority priority;
  final Actor actor;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await SharePriority(
      priority,
      actor.id.toUuid(),
      add: false,
    ).run(context);
    if (result is CommandDone) {
      // Pull sync data so the local database is updated before refresh
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityMember);

      return CommandRefresh(
        message: 'Invitation canceled for ${actor.nameOrEmail}',
      );
    }
    return result;
  }
}

/// Invite an existing contact - runs immediately (no confirmation needed).
class InviteContact extends Command {
  InviteContact(this.priority, this.actor)
    : super(
        title: actor.nameOrEmail,
        subtitle: actor.name != null ? actor.email : null,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
        icon: PlotIcon.share,
      );

  final Priority priority;
  final Actor actor;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final result = await SharePriority(
      priority,
      actor.id.toUuid(),
      add: true,
    ).run(context);
    if (result is CommandDone) {
      // Pull sync data so the local database has the member before refresh
      await SyncOrchestrator.instance.pull(SyncOrchestrator.actor);
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityMember);

      return CommandRefresh(message: 'Invited ${actor.nameOrEmail}');
    }
    return result;
  }
}

/// Invite by email (creates contact if needed) - runs immediately.
class InviteByEmail extends Command {
  InviteByEmail(this.priority, this.email)
    : super(
        title: 'Invite $email',
        subtitle: 'Invite by email',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
        icon: PlotIcon.add,
      );

  final Priority priority;
  final String email;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      // API will create contact and invite in one call
      await api.post<Map<String, dynamic>>(
        '/priority/${priority.id}/share',
        body: {
          'add': [email], // API accepts email strings
          'remove': <String>[],
        },
      );
      // Pull sync data so the local database has the new contact and member
      // before the modal refreshes
      await SyncOrchestrator.instance.pull(SyncOrchestrator.actor);
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityMember);

      return CommandRefresh(message: 'Invitation sent to $email');
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}
