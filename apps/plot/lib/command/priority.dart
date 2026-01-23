import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'command.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/analytics/tracker.dart';
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
                  ),
                  FormSelect<Priority>(
                    key: 'parent',
                    label: 'Parent',
                    initialValue: defaultParent,
                    items: (search) => Priority.get(
                      order: PriorityOrder.nested,
                      search: search,
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
                    label: 'Create',
                    onSubmit: (values) {
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
                    label: 'Save',
                    onSubmit: (values) {
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
  ManagePrioritySharing(priority),
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
  NewAction(),
  OpenNextActivity(),
  OpenPreviousActivity(),
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
/// Shows three sections: Sharing (users with access), Invited (pending), and Share (available contacts).
class ManagePrioritySharing extends ShowCommands {
  ManagePrioritySharing(this.priority)
    : super(
        title: 'Share',
        icon: PlotIcon.share,
        commands: (context) => _getSharingCommands(priority),
      );

  final Priority priority;

  static Future<Commands> _getSharingCommands(Priority priority) async {
    // Fetch all actors for initial ContactGroup cache
    final allActors = await Actor.get(
      types: [ActorType.user, ActorType.contact],
      limit: 100,
    );

    return Commands(
      prompt: 'Share with',
      emptyMessage: 'Enter an email address to invite someone else',
      groups: [
        // Use dynamic groups that re-fetch on each list() call
        SharingGroup(title: 'Sharing', priority: priority),
        InvitationGroup(title: 'Invited', priority: priority),
        ContactGroup(
          title: 'Share',
          priority: priority,
          excludeActorIds: {}, // Now unused, will be dynamically computed
          initialActors: allActors, // Cache for first empty search
        ),
      ],
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

    // Dynamically fetch exclude set from current users and invitations
    final priorityUsers = await PriorityUser.getForPriority(priority.id);
    final invitations = await PriorityInvitation.getForPriority(priority.id);

    // Build exclude set
    final excludeActorIds = <Uuid>{};

    // Add users with access
    for (final pu in priorityUsers) {
      if (pu.userId != Base.userId) {
        final actor = await Actor.getByUserId(pu.userId);
        if (actor != null) {
          excludeActorIds.add(actor.id.toUuid());
        }
      }
    }

    // Add invited users
    for (final inv in invitations) {
      excludeActorIds.add(inv.contactId);
    }

    // Filter out excluded and self
    final filteredActors = actors
        .where((a) => !excludeActorIds.contains(a.id.toUuid()) && !a.self)
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

class SharingGroup extends CommandGroup {
  SharingGroup({required super.title, required this.priority});

  final Priority priority;

  @override
  Future<List<Command>> list({String? search}) async {
    // Re-fetch users on each call
    final users = await PriorityUser.getForPriority(priority.id);

    // Get actors and build commands
    final commands = <Command>[];
    for (final pu in users) {
      // Skip current user - can't remove own access
      if (pu.userId == Base.userId) continue;

      // Get the Actor for this user (via contact.user_id lookup)
      final actor = await Actor.getByUserId(pu.userId);
      if (actor != null) {
        // Filter based on search
        if (search != null && search.isNotEmpty) {
          final searchLower = search.toLowerCase();
          if (!actor.nameOrEmail.toLowerCase().contains(searchLower)) {
            continue;
          }
        }
        commands.add(EditSharingCommand(priority, actor));
      }
    }

    return commands;
  }
}

class InvitationGroup extends CommandGroup {
  InvitationGroup({required super.title, required this.priority});

  final Priority priority;

  @override
  Future<List<Command>> list({String? search}) async {
    // Re-fetch invitations on each call
    final invitations = await PriorityInvitation.getForPriority(priority.id);

    // Get actors and build commands
    final commands = <Command>[];
    for (final inv in invitations) {
      try {
        // Create command using factory method that looks up both actors
        final command = await EditInvitationCommand.fromInvitation(
          priority,
          inv,
        );

        // Filter based on search
        if (search != null && search.isNotEmpty) {
          final searchLower = search.toLowerCase();
          if (!command.actor.nameOrEmail.toLowerCase().contains(searchLower)) {
            continue;
          }
        }

        commands.add(command);
      } catch (e) {
        // Skip if actor not found
      }
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
        icon: PlotIcon.users,
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
              text: '${actor.nameOrEmail} has access to this priority.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'remove',
              label: 'Remove Access',
              onSubmit: (_) => _RemoveSharingCommand(priority, actor),
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
        title: 'Remove Access',
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
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityUser);
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityInvitation);

      return CommandRefresh(message: 'Access removed for ${actor.nameOrEmail}');
    }
    return result;
  }
}

/// View/manage a pending invitation - opens a form with cancel option.
class EditInvitationCommand extends ShowForm {
  EditInvitationCommand._(this.priority, this.actor, String inviterName)
    : super(
        title: actor.nameOrEmail,
        subtitle: 'Invited by $inviterName',
        icon: PlotIcon.waiting,
        form: (context) => _buildForm(priority, actor),
      );

  final Priority priority;
  final Actor actor;

  /// Create an EditInvitationCommand from a PriorityInvitation.
  /// Looks up both the invited actor and the inviter to display proper names.
  static Future<EditInvitationCommand> fromInvitation(
    Priority priority,
    PriorityInvitationRow invitation,
  ) async {
    // Look up the invited actor
    final actor = await Actor.getOne(ActorId.fromUuid(invitation.contactId));

    // Look up the inviter actor
    final inviter = await Actor.getByUserId(invitation.invitedBy);
    final inviterName = inviter?.nameOrEmail ?? 'Unknown';

    // Create and return the command with inviter info
    return EditInvitationCommand._(priority, actor, inviterName);
  }

  static Future<FormData> _buildForm(Priority priority, Actor actor) async {
    return FormData(
      title: actor.nameOrEmail,
      groups: [
        StaticFormGroup(
          items: [
            FormInfo(
              key: 'info',
              text: 'Invitation pending for ${actor.nameOrEmail}.',
            ),
            FormDivider(key: 'divider'),
            FormButton(
              key: 'cancel',
              label: 'Cancel Invitation',
              onSubmit: (_) => _CancelInvitationCommand(priority, actor),
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
        title: 'Cancel Invitation',
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
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityInvitation);

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
      // Pull sync data so the local database has the invitation before refresh
      await SyncOrchestrator.instance.pull(SyncOrchestrator.actor);
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityInvitation);

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
      // Pull sync data so the local database has the new contact and invitation
      // before the modal refreshes
      await SyncOrchestrator.instance.pull(SyncOrchestrator.actor);
      await SyncOrchestrator.instance.pull(SyncOrchestrator.priorityInvitation);

      return CommandRefresh(message: 'Invitation sent to $email');
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}
