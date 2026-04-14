import 'dart:async';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
/// Share a thread with one or more topics.
class ShareThreadWithTopics extends Command {
  ShareThreadWithTopics({
    required this.threadId,
    required this.addTopicIds,
    this.removeTopicIds = const [],
  }) : super(
          title: 'Share thread with topics',
          eventObject: EventObject.activity,
          eventAction: EventAction.updated,
        );

  final String threadId;
  final List<String> addTopicIds;
  final List<String> removeTopicIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/thread/$threadId/share',
        body: {
          'addTopics': addTopicIds,
          'removeTopics': removeTopicIds,
        },
      );
      unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.thread));
      return const CommandDone(message: 'Shared with topics');
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

/// Add contacts to a topic's member list.
class AddTopicMembers extends Command {
  AddTopicMembers({
    required this.topicId,
    required this.contactIds,
  }) : super(
          title: 'Add topic members',
          eventObject: EventObject.activity,
          eventAction: EventAction.added,
        );

  final String topicId;
  final List<String> contactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/topic/$topicId/members',
        body: {'contactIds': contactIds},
      );
      unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.topic));
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

/// Remove contacts from a topic's member list.
class RemoveTopicMembers extends Command {
  RemoveTopicMembers({
    required this.topicId,
    required this.contactIds,
  }) : super(
          title: 'Remove topic members',
          eventObject: EventObject.activity,
          eventAction: EventAction.deleted,
        );

  final String topicId;
  final List<String> contactIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.deleteWithBody<Map<String, dynamic>>(
        '/topic/$topicId/members',
        body: {'contactIds': contactIds},
      );
      unawaited(SyncOrchestrator.instance.pull(SyncOrchestrator.topic));
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
