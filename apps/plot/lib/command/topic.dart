import 'command.dart';
import 'package:plot/analytics/conventions.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/widget/widget.dart';

/// Create a Plot topic (a Plot-only channel).
///
/// Mirrors the group-create commands in `group.dart`: posts to `POST /topic`
/// with the topic's name, optional team scope, and initial members (contacts +
/// groups). Returns as soon as the POST succeeds so the host modal can close
/// immediately — the topic sync that surfaces it in the Channels list runs
/// *after* the modal is dismissed (see `_createTopic` in `new_thread.dart`),
/// not on this command's critical path. Awaiting the sync here would block the
/// modal close on two network round-trips (and leave it stuck open if the sync
/// threw), which is the bug this split fixes.
class CreateTopic extends Command {
  CreateTopic({
    required this.name,
    this.teamId,
    this.contactIds = const [],
    this.groupIds = const [],
  }) : super(
          title: 'Create topic',
          icon: PlotIcon.save,
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
      // Don't await the topic sync here — the caller pulls after the modal
      // closes so the new topic surfaces in the Channels list without keeping
      // the modal open during the network round-trips.
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
