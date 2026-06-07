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
    final companion = GroupsCompanion.insert(
      name: name,
      type: 'private',
      joinPolicy: 'member',
      privacy: Value(privacy),
      memberContactIds: Value(memberContactIds),
      isAdmin: const Value(true), // optimistic: creator is admin; reconciled on next pull
      canPost: const Value(true),
      canAddress: const Value(true),
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, companion, GroupsBase());
    return const CommandDone(message: 'Group created');
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
      pending: const Value(2),
    );
    await Store.get.save(Store.get.groups, updated, GroupsBase());
    return const CommandDone(message: 'Members removed');
  }
}
