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
    try {
      await api.post<Map<String, dynamic>>(
        '/group/$groupId/members',
        body: {'contactIds': contactIds},
      );
      unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.group));
      return const CommandDone(message: 'Members added');
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
    try {
      await api.deleteWithBody<Map<String, dynamic>>(
        '/group/$groupId/members',
        body: {'contactIds': contactIds},
      );
      unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.group));
      return const CommandDone(message: 'Members removed');
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
