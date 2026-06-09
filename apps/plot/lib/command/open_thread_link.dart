import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'base.dart';
import 'logging.dart';

/// Opens the thread's primary canonical link in its source application.
/// Surfaced only when a primary canonical link with a URL exists (the call
/// sites gate on that — see threadCommands).
class OpenThreadLink extends Command {
  OpenThreadLink({required this.url, required this.connectorName})
    : super(
        title: connectorName != null
            ? 'Open in $connectorName'
            : 'Open in source',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.arrowUpRightFromSquare,
      );

  final String url;
  final String? connectorName;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return const CommandMessage('Invalid link', isError: true);
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to open thread link: $url', e, t);
      return const CommandMessage('Failed to open link', isError: true);
    }
  }
}
