import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/router.dart';
import 'package:plot/state/now.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/widget/widget.dart';
import 'command.dart';
import 'logging.dart';

/// Opens the NewThreadPage with a pre-filled link from a share intent.
class OpenSharedLink extends Command {
  OpenSharedLink(this.url)
    : super(
        title: 'Open shared link',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
      );

  final String url;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    log.info('OpenSharedLink.run: url=$url');
    try {
      final nowBloc = context.read<NowBloc>();
      final nowState = nowBloc.state;
      if (nowState is! NowLoaded) {
        log.warning(
          'Cannot open shared link: NowBloc not loaded (state=${nowState.runtimeType})',
        );
        return const CommandDone();
      }

      final priorityId = nowState.priority.id.toShortString();
      log.info(
        'OpenSharedLink: pushing PriorityRoute($priorityId) > NewThreadRoute(sharedUrl)',
      );

      // Use push (not navigate/CommandRoute) because on cold start the
      // router's own initial navigation is resolving to the same default
      // PriorityRoute at the same moment — navigate() then merges/dedupes
      // and drops our `children: [NewThreadRoute]`, leaving the default
      // empty child (PriorityOnlyRoute) visible instead.
      await context.router.root.push(
        PriorityRoute(
          priorityIdString: priorityId,
          children: [NewThreadRoute(sharedUrl: url)],
        ),
      );
      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to open shared link: $url', e, t);
      return CommandMessage('Failed to open shared link', isError: true);
    }
  }
}

/// Generic, thread-independent snapshot of a "share with" selection.
/// Both the thread-sharing flow and the per-priority defaults flow build
/// their share picker on top of this.
class SharedSelection {
  const SharedSelection({
    this.contacts = const [],
    this.groups = const [],
    this.inviteEmails = const [],
  });

  final List<Uuid> contacts;
  final List<Uuid> groups;
  final List<String> inviteEmails;

  bool get isEmpty =>
      contacts.isEmpty && groups.isEmpty && inviteEmails.isEmpty;

  SharedSelection copyWith({
    List<Uuid>? contacts,
    List<Uuid>? groups,
    List<String>? inviteEmails,
  }) => SharedSelection(
    contacts: contacts ?? this.contacts,
    groups: groups ?? this.groups,
    inviteEmails: inviteEmails ?? this.inviteEmails,
  );
}

/// Caches sorted sharing candidates (people + groups, interleaved by MRU)
/// by search string for the lifetime of a single share-picker modal.
/// Toggling a row doesn't change the candidate pool, only which side of
/// the "Shared" / suggestions partition each candidate falls on, so we
/// avoid re-running the thread scan in [Actor.getSortedShareCandidates]
/// on every toggle.
class ShareCandidatesCache {
  final Map<String, List<ShareCandidate>> _byQuery = {};

  Future<List<ShareCandidate>> get({
    required String? search,
    required Priority? priority,
  }) async {
    final key = (search ?? '').toLowerCase();
    final cached = _byQuery[key];
    if (cached != null) return cached;
    final fresh = await Actor.getSortedShareCandidates(
      search: search,
      priority: priority,
    );
    _byQuery[key] = fresh;
    return fresh;
  }
}

bool isValidShareEmail(String value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);

/// Builds the command list for a generic share picker operating on a
/// [SharedSelection]. Callers pass the current selection and an [onUpdate]
/// callback that persists the new selection.
///
/// [priority] scopes the contact suggestions to people the user typically
/// shares with in that priority. [injectSelf] adds the current user as a
/// selected entry when not already present (used by draft threads and
/// priority-defaults flows where self is implicit).
Future<Commands> buildSharedSelectionCommands({
  required SharedSelection selection,
  required Future<void> Function(SharedSelection) onUpdate,
  required ShareCandidatesCache candidates,
  Priority? priority,
  bool injectSelf = false,
}) async {
  // Resolve groups.
  final sharedGroups = <GroupRow>[];
  for (final groupId in selection.groups) {
    final group = await Group.getOne(groupId);
    if (group != null) sharedGroups.add(group);
  }

  // Resolve shared actors, deduping by actor id.
  final sharedActors = <Actor>[];
  final seenActorIds = <ActorId>{};
  for (final contactId in selection.contacts) {
    try {
      final actor = await Actor.getOne(ActorId.fromUuid(contactId));
      if (seenActorIds.add(actor.id)) sharedActors.add(actor);
    } catch (_) {
      // Skip unresolvable contacts
    }
  }

  if (injectSelf) {
    final selfIndex = sharedActors.indexWhere((a) => a.self);
    if (selfIndex < 0) {
      final primarySelfId = Base.actorIdOrNull;
      if (primarySelfId != null) {
        try {
          final selfActor = await Actor.getOne(primarySelfId);
          sharedActors.insert(0, selfActor);
          seenActorIds.add(selfActor.id);
        } catch (_) {}
      }
    } else if (selfIndex > 0) {
      final self = sharedActors.removeAt(selfIndex);
      sharedActors.insert(0, self);
    }
  }

  final sharedActorIds = sharedActors.map((a) => a.id).toList();

  Command toggleActor(Actor actor) =>
      ShareSelectionActor(selection, actor, onUpdate: onUpdate);

  Command toggleInvite(String email) =>
      ShareSelectionInvite(selection, email, onUpdate: onUpdate);

  Command toggleGroup(GroupRow group) =>
      ShareSelectionGroup(selection, group, onUpdate: onUpdate);

  return Commands(
    prompt: 'Share with',
    emptyMessage: 'Enter an email address to invite someone',
    groups: [
      if (sharedActors.isNotEmpty ||
          sharedGroups.isNotEmpty ||
          selection.inviteEmails.isNotEmpty)
        StaticCommandGroup(
          title: 'Shared',
          commands: [
            ...sharedGroups.map(toggleGroup),
            ...sharedActors.map(toggleActor),
            ...selection.inviteEmails.map(toggleInvite),
          ],
        ),
      _SelectionShareSuggestionsGroup(
        selection: selection,
        excludeActorIds: sharedActorIds,
        excludeGroupIds: selection.groups.toSet(),
        onUpdate: onUpdate,
        candidates: candidates,
        priority: priority,
      ),
    ],
  );
}

/// Single merged "people + groups" suggestion list, ordered by the
/// shared MRU sort from [Actor.getSortedShareCandidates]. Replaces the
/// older split where alphabetical groups always came before recent
/// contacts and pushed them out of view.
class _SelectionShareSuggestionsGroup extends CommandGroup {
  _SelectionShareSuggestionsGroup({
    required this.selection,
    required this.excludeActorIds,
    required this.excludeGroupIds,
    required this.onUpdate,
    required this.candidates,
    required this.priority,
  });

  final SharedSelection selection;
  final List<ActorId> excludeActorIds;
  final Set<Uuid> excludeGroupIds;
  final Future<void> Function(SharedSelection) onUpdate;
  final ShareCandidatesCache candidates;
  final Priority? priority;

  @override
  Future<List<Command>> list({String? search}) async {
    final sorted = await candidates.get(search: search, priority: priority);
    final excludedActorIds = excludeActorIds.toSet();
    final commands = <Command>[];
    for (final candidate in sorted) {
      switch (candidate) {
        case ActorShareCandidate(:final actor):
          if (excludedActorIds.contains(actor.id)) continue;
          commands.add(
            ShareSelectionActor(selection, actor, onUpdate: onUpdate),
          );
        case GroupShareCandidate(:final group):
          if (excludeGroupIds.contains(group.id)) continue;
          commands.add(
            ShareSelectionGroup(selection, group, onUpdate: onUpdate),
          );
      }
    }

    if (search != null && isValidShareEmail(search)) {
      final normalized = search.toLowerCase();
      final emailExists = sorted.any(
        (c) =>
            c is ActorShareCandidate &&
            c.actor.email?.toLowerCase() == normalized,
      );
      final alreadyInvited = selection.inviteEmails.contains(normalized);
      if (!emailExists && !alreadyInvited) {
        commands.insert(
          0,
          ShareSelectionInvite(selection, normalized, onUpdate: onUpdate),
        );
      }
    }

    return commands;
  }
}

class ShareSelectionActor extends Command {
  ShareSelectionActor(this.selection, this.actor, {required this.onUpdate})
    : _isShared = selection.contacts.contains(actor.id.toUuid()),
      super(
        title: actor.nameOrEmail,
        eventObject: EventObject.activity,
        eventAction: selection.contacts.contains(actor.id.toUuid())
            ? EventAction.updated
            : EventAction.shared,
        icon: selection.contacts.contains(actor.id.toUuid())
            ? PlotIcon.user
            : PlotIcon.shareAdd,
        on: selection.contacts.contains(actor.id.toUuid()),
      );

  final SharedSelection selection;
  final Actor actor;
  final Future<void> Function(SharedSelection) onUpdate;
  final bool _isShared;

  @override
  String? get subtitle => actor.name != null ? actor.email : null;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      Avatar(actor: actor);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final contactUuid = actor.id.toUuid();
      final newContacts = _isShared
          ? selection.contacts.where((id) => id != contactUuid).toList()
          : [...selection.contacts, contactUuid];
      await onUpdate(selection.copyWith(contacts: newContacts));
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ShareSelectionActor: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to update sharing', isError: true);
    }
  }
}

class ShareSelectionGroup extends Command {
  ShareSelectionGroup(this.selection, this.group, {required this.onUpdate})
    : _isShared = selection.groups.contains(group.id),
      super(
        title: group.name,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        icon: PlotIcon.users,
        on: selection.groups.contains(group.id),
      );

  final SharedSelection selection;
  final GroupRow group;
  final Future<void> Function(SharedSelection) onUpdate;
  final bool _isShared;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final newGroups = _isShared
          ? selection.groups.where((id) => id != group.id).toList()
          : [...selection.groups, group.id];
      await onUpdate(selection.copyWith(groups: newGroups));
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ShareSelectionGroup: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to update sharing', isError: true);
    }
  }
}

class ShareSelectionInvite extends Command {
  ShareSelectionInvite(this.selection, this.email, {required this.onUpdate})
    : _isInvited = selection.inviteEmails.contains(email.toLowerCase()),
      super(
        title: selection.inviteEmails.contains(email.toLowerCase())
            ? email
            : 'Invite $email',
        subtitle: selection.inviteEmails.contains(email.toLowerCase())
            ? 'Pending invitation'
            : 'Invite by email',
        eventObject: EventObject.activity,
        eventAction: selection.inviteEmails.contains(email.toLowerCase())
            ? EventAction.updated
            : EventAction.shared,
        icon: selection.inviteEmails.contains(email.toLowerCase())
            ? PlotIcon.user
            : PlotIcon.shareAdd,
        on: selection.inviteEmails.contains(email.toLowerCase()),
      );

  final SharedSelection selection;
  final String email;
  final Future<void> Function(SharedSelection) onUpdate;
  final bool _isInvited;

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) =>
      Avatar(email: email);

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final normalized = email.toLowerCase();
      final newEmails = _isInvited
          ? selection.inviteEmails.where((e) => e != normalized).toList()
          : [...selection.inviteEmails, normalized];
      await onUpdate(selection.copyWith(inviteEmails: newEmails));
      return const CommandRefresh();
    } catch (e, stackTrace) {
      log.severe('Error in ShareSelectionInvite: $e', e, stackTrace);
      Tracker.captureException(e, stackTrace);
      return CommandMessage('Failed to update invitation', isError: true);
    }
  }
}

/// Summary icon for a [SharedSelection]: a user icon with a count badge when
/// more than one party is selected, falling back to the "share+" glyph.
IconData sharedSelectionIcon(SharedSelection selection) =>
    selection.isEmpty ? PlotIcon.shareAdd : PlotIcon.user;

/// One-line truncated text describing the selection, suitable for display in
/// a SelectTile-style summary.
String sharedSelectionSummary(
  SharedSelection selection, {
  required Map<Uuid, String> groupNames,
  required Map<Uuid, String> contactNames,
}) {
  final parts = <String>[
    for (final id in selection.groups) groupNames[id] ?? 'Group',
    for (final id in selection.contacts) contactNames[id] ?? 'Someone',
    ...selection.inviteEmails,
  ];
  if (parts.isEmpty) return '';
  return parts.join(', ');
}

/// Generic share picker over a [SharedSelection]. Thread-specific pickers
/// (which layer on self-removal guards and group-member re-add) wrap this.
class PickShared extends ShowCommands {
  factory PickShared({
    required SharedSelection selection,
    required Future<void> Function(SharedSelection) onUpdate,
    Priority? priority,
    bool injectSelf = false,
    String? title,
  }) {
    final ref = [selection];
    final cache = ShareCandidatesCache();

    Future<void> onChange(SharedSelection next) async {
      ref[0] = next;
      await onUpdate(next);
    }

    return PickShared._(
      title: title ?? (selection.isEmpty ? 'Share' : 'Shared'),
      icon: sharedSelectionIcon(selection),
      commandsBuilder: (context) => buildSharedSelectionCommands(
        selection: ref[0],
        onUpdate: onChange,
        candidates: cache,
        priority: priority,
        injectSelf: injectSelf,
      ),
    );
  }

  PickShared._({
    required super.title,
    required IconData icon,
    required Future<Commands> Function(BuildContext) commandsBuilder,
  }) : super(
         icon: icon,
         commandsBuilder: commandsBuilder,
         showFilter: true,
         eventObject: EventObject.activity,
         eventAction: EventAction.updated,
         shortcut: platformSingleActivator(
           LogicalKeyboardKey.keyS,
           shift: true,
         ),
       );
}
