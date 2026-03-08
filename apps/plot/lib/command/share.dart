import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/router.dart';
import 'package:plot/state/now.dart';
import 'command.dart';
import 'logging.dart';

/// Opens the NewThreadPage with a pre-filled link from a share intent.
class OpenSharedLink extends Command {
  OpenSharedLink(this.url)
    : super(
        title: 'Open Shared Link',
        eventObject: EventObject.activity,
        eventAction: EventAction.added,
      );

  final String url;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final nowBloc = context.read<NowBloc>();
      final nowState = nowBloc.state;
      if (nowState is! NowLoaded) {
        log.warning('Cannot open shared link: NowBloc not loaded');
        return const CommandDone();
      }

      final priorityId = nowState.priority.id.toShortString();

      return CommandRoute(
        PriorityRoute(
          priorityIdString: priorityId,
          children: [NewThreadRoute(sharedUrl: url)],
        ),
      );
    } catch (e, t) {
      log.warning('Failed to open shared link: $url', e, t);
      return CommandMessage('Failed to open shared link', isError: true);
    }
  }
}
