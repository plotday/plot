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
