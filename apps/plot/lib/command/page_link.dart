import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/env.dart';
import 'package:plot/router.dart';
import 'command.dart';
import 'logging.dart';

class CopyPageLink extends Command {
  CopyPageLink()
    : super(
        title: 'Copy Page Link',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.link,
        shortcut: const SingleActivator(
          LogicalKeyboardKey.keyC,
          meta: true,
          shift: true,
        ),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    log.info('CopyPageLink command executed');
    try {
      final currentPath = context.router.currentPath;
      final fullUrl = '${Env.appBaseUrl}$currentPath';

      await Clipboard.setData(ClipboardData(text: fullUrl));
      return CommandMessage('Page link copied to clipboard');
    } catch (e, t) {
      log.warning("Copy page link failed", e, t);
      return CommandMessage('Failed to copy page link', isError: true);
    }
  }
}

class OpenPageLink extends Command {
  OpenPageLink(this.url)
    : super(
        title: 'Open Page Link',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
      );

  final String url;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;

      if (segments.isEmpty) {
        return CommandMessage('Invalid link: $url', isError: true);
      }

      // Navigate based on path structure
      if (segments.first == 'priorities') {
        // Navigate to priorities page
        context.router.push(PrioritiesRoute());
      } else if (segments.length == 1) {
        // Navigate to priority page: /priorityId
        context.router.push(PriorityRoute(priorityIdString: segments[0]));
      } else if (segments.length >= 2) {
        // Navigate to nested route: /priorityId/activityId or /priorityId/new
        if (segments[1] == 'new') {
          context.router.push(
            PriorityRoute(
              priorityIdString: segments[0],
              children: [NewActivityRoute()],
            ),
          );
        } else {
          context.router.push(
            PriorityRoute(
              priorityIdString: segments[0],
              children: [ActivityRoute(activityIdString: segments[1])],
            ),
          );
        }
      }

      return const CommandDone();
    } catch (e, t) {
      log.warning('Failed to open page link: $url', e, t);
      return CommandMessage('Failed to open link', isError: true);
    }
  }
}

class OpenCopiedPageLink extends Command {
  OpenCopiedPageLink()
    : super(
        title: 'Open Copied Page Link',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.link,
        shortcut: const SingleActivator(
          LogicalKeyboardKey.keyV,
          meta: true,
          shift: true,
        ),
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    String? link;
    try {
      final data = await Clipboard.getData('text/plain');
      link = data?.text;

      // Check if context is still mounted before navigation
      if (!context.mounted) {
        return const CommandDone();
      }
    } catch (e, t) {
      log.warning("Open copied page link failed", e, t);
      return CommandMessage('Failed to get clipboard link', isError: true);
    }

    if (link == null || link.isEmpty) {
      return CommandMessage('No link in clipboard', isError: true);
    }

    // Delegate navigation to OpenPageLink command
    return await OpenPageLink(link).run(context);
  }
}
