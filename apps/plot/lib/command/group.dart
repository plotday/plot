import 'dart:async';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

/// Share a thread with one or more groups.
class ShareThreadWithGroups extends Command {
  ShareThreadWithGroups({
    required this.threadId,
    required this.addGroupIds,
    this.removeGroupIds = const [],
  }) : super(
          title: 'Share thread with groups',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final String threadId;
  final List<String> addGroupIds;
  final List<String> removeGroupIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/thread/$threadId/share',
        body: {
          'addGroups': addGroupIds,
          'removeGroups': removeGroupIds,
        },
      );
      unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.thread));
      return const CommandDone(message: 'Shared with groups');
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException {
      return const CommandMessage(
        "You're offline. Please try again when connected.",
        isError: true,
      );
    }
  }
}

/// Create a new group.
class CreateGroup extends Command {
  CreateGroup({
    required this.name,
    this.privacy = 'open',
    this.memberContactIds = const [],
  }) : super(
          title: 'Create group',
          eventObject: EventObject.activity,
          eventAction: EventAction.added,
        );

  final String name;
  final String privacy;
  final List<Uuid> memberContactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final id = Uuid.generate();
    final companion = GroupsCompanion.insert(
      id: Value(id),
      name: name,
      type: 'private',
      joinPolicy: 'member',
      privacy: Value(privacy),
      memberContactIds: Value(memberContactIds),
      // Send the initial member set only when there are members; a brand-new
      // empty group has nothing for the server diff to remove.
      membersDirty: Value(memberContactIds.isNotEmpty),
      isAdmin: const Value(true), // optimistic: creator is admin; reconciled on next pull
      canPost: const Value(true),
      canAddress: const Value(true),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, companion, GroupsBase());
    return CommandDone(message: 'Group created', createdId: id.toString());
  }
}

/// Rename an existing group (admin-only; enforced server-side).
class RenameGroup extends Command {
  RenameGroup({required this.groupId, required this.name})
    : super(
        title: 'Rename group',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Uuid groupId;
  final String name;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = Group.fromCache(groupId);
    if (existing == null) {
      return const CommandMessage('Group not found', isError: true);
    }
    final updated = existing.copyWith(name: name, pending: const Value(2));
    await Store.get.save(Store.get.groups, updated, GroupsBase());
    return const CommandDone(message: 'Group renamed');
  }
}

/// Add contacts to a group's member list.
class AddGroupMembers extends Command {
  AddGroupMembers({
    required this.groupId,
    required this.contactIds,
  }) : super(
          title: 'Add group members',
          eventObject: EventObject.activity,
          eventAction: EventAction.added,
        );

  final String groupId;
  final List<String> contactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = Group.fromCache(Uuid.fromString(groupId));
    if (existing == null) {
      return const CommandMessage('Group not found', isError: true);
    }
    final current = existing.memberContactIds ?? const <Uuid>[];
    final toAdd = contactIds.map(Uuid.fromString);
    final merged = {...current, ...toAdd}.toList();
    final updated = existing.copyWith(
      memberContactIds: Value(merged),
      membersDirty: const Value(true),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, updated, GroupsBase());
    return const CommandDone(message: 'Members added');
  }
}

/// Remove contacts from a group's member list.
class RemoveGroupMembers extends Command {
  RemoveGroupMembers({
    required this.groupId,
    required this.contactIds,
  }) : super(
          title: 'Remove group members',
          eventObject: EventObject.activity,
          eventAction: EventAction.deleted,
        );

  final String groupId;
  final List<String> contactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final existing = Group.fromCache(Uuid.fromString(groupId));
    if (existing == null) {
      return const CommandMessage('Group not found', isError: true);
    }
    final removing = contactIds.map(Uuid.fromString).toSet();
    final current = existing.memberContactIds ?? const <Uuid>[];
    final remaining = current.where((u) => !removing.contains(u)).toList();
    final updated = existing.copyWith(
      memberContactIds: Value(remaining),
      membersDirty: const Value(true),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, updated, GroupsBase());
    return const CommandDone(message: 'Members removed');
  }
}

/// The membership delta between a group's previous and next member sets.
class GroupMembershipDiff {
  const GroupMembershipDiff({required this.added, required this.removed});
  final List<Uuid> added;
  final List<Uuid> removed;
}

/// Computes which contacts were added/removed between [prev] and [next].
/// Order-independent; dedupe relies on Uuid value equality.
GroupMembershipDiff groupMembershipDiff(List<Uuid> prev, List<Uuid> next) {
  final prevSet = prev.toSet();
  final nextSet = next.toSet();
  return GroupMembershipDiff(
    added: next.where((u) => !prevSet.contains(u)).toList(),
    removed: prev.where((u) => !nextSet.contains(u)).toList(),
  );
}

/// Performs the save side of [EditGroup]: create a new group, or rename +
/// apply a membership diff on an existing one. Reuses the headless write
/// commands so offline/sync behavior is identical.
class _SaveGroupEdit extends Command {
  _SaveGroupEdit({
    required this.groupId,
    required this.name,
    required this.originalName,
    required this.members,
    required this.originalMembers,
  }) : super(
          title: 'Save group',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final Uuid? groupId;
  final String name;
  final String originalName;
  final List<Uuid> members;
  final List<Uuid> originalMembers;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (groupId == null) {
      return CreateGroup(name: name, memberContactIds: members).run(context);
    }
    final gid = groupId!;
    var changed = false;
    if (name != originalName && name.isNotEmpty) {
      final r = await RenameGroup(groupId: gid, name: name).run(context);
      if (r is CommandMessage && r.isError) return r;
      changed = true;
    }
    if (!context.mounted) return const CommandSkipped();
    final diff = groupMembershipDiff(originalMembers, members);
    if (diff.added.isNotEmpty) {
      final r = await AddGroupMembers(
        groupId: gid.toString(),
        contactIds: diff.added.map((u) => u.toString()).toList(),
      ).run(context);
      if (r is CommandMessage && r.isError) return r;
      changed = true;
    }
    if (!context.mounted) return const CommandSkipped();
    if (diff.removed.isNotEmpty) {
      final r = await RemoveGroupMembers(
        groupId: gid.toString(),
        contactIds: diff.removed.map((u) => u.toString()).toList(),
      ).run(context);
      if (r is CommandMessage && r.isError) return r;
      changed = true;
    }
    return changed
        ? const CommandDone(message: 'Group updated')
        : const CommandSkipped();
  }
}

/// Edit a group, create a new group, or name an ad-hoc set of contacts as a
/// group. groupId == null => create (used by the ad-hoc row menu and the
/// "+ Group" header button); groupId != null => rename + membership diff.
class EditGroup extends Command {
  EditGroup({
    this.groupId,
    this.initialName = '',
    this.initialMemberContactIds = const [],
  }) : super(
          title: groupId == null ? 'Create group' : 'Edit group',
          eventObject: EventObject.activity,
          eventAction:
              groupId == null ? EventAction.added : EventAction.updated,
        );

  final Uuid? groupId;
  final String initialName;
  final List<Uuid> initialMemberContactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final items = <FormItem>[
      FormTextInput(
        key: 'name',
        label: 'Name',
        required: true,
        initialValue: initialName,
        placeholder: 'e.g. Marketing',
      ),
      FormShareSelect(
        key: 'members',
        label: 'Members',
        placeholder: 'Add people and groups',
        initialValue: SharedSelection(contacts: initialMemberContactIds),
      ),
      FormButton(
        key: 'save',
        isPrimary: true,
        buildCommand: (values) {
          final name = (values['name'] as String?)?.trim() ?? '';
          final sel = values['members'] as SharedSelection?;
          final members = sel?.contacts ?? const <Uuid>[];
          return _SaveGroupEdit(
            groupId: groupId,
            name: name,
            originalName: initialName,
            members: members,
            originalMembers: initialMemberContactIds,
          );
        },
      ),
    ];
    final form = FormData(
      title: groupId == null ? 'Create group' : 'Edit group',
      dismissable: true,
      groups: [StaticFormGroup(items: items)],
    );
    final groups = await form.list();
    if (!context.mounted) return const CommandSkipped();
    return FormModal(
      form,
      groups: groups,
      rootContext: context,
      constraints: const BoxConstraints(maxHeight: 520, maxWidth: 460),
    ).run(context);
  }
}
