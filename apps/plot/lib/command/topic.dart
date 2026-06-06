import 'command.dart';
import 'package:plot/analytics/conventions.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

/// Create a Plot topic (a Plot-only channel) and pull it into the local store.
///
/// Mirrors the group-create commands in `group.dart`: posts to `POST /topic`
/// with the topic's name, optional team scope, and initial members (contacts +
/// groups), then **awaits** a topic sync so the new topic is locally available
/// (and surfaces in the new-thread Channels section) before this returns.
class CreateTopic extends Command {
  CreateTopic({
    required this.name,
    this.teamId,
    this.contactIds = const [],
    this.groupIds = const [],
  }) : super(
          title: 'Create topic',
          eventObject: EventObject.activity,
          eventAction: EventAction.added,
        );

  final String name;

  /// Team scope: null = Personal.
  final BigInt? teamId;

  /// Initial member contacts and groups.
  final List<String> contactIds;
  final List<String> groupIds;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/topic',
        body: {
          'name': name,
          if (teamId != null) 'teamId': teamId!.toInt(),
          if (contactIds.isNotEmpty) 'contactIds': contactIds,
          if (groupIds.isNotEmpty) 'groupIds': groupIds,
        },
      );
      // Await the pull so the created topic is in the local store before the
      // caller refreshes the Channels list.
      await Topic.pull();
      return const CommandDone(message: 'Topic created');
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
