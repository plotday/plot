import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/env.dart';
import 'package:plot/page/invite.dart';
import 'package:plot/router.dart';
import 'package:plot/util/shortcut.dart';
import 'command.dart';
import 'logging.dart';

class CopyPageLink extends Command {
  CopyPageLink()
    : super(
        title: 'Copy page link',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.link,
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.keyC,
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

/// Parsed result of a Plot internal URL.
class PlotLink {
  const PlotLink({this.priorityId, this.threadId});

  /// Short-string IDs from the URL path segments.
  final String? priorityId;
  final String? threadId;
}

class OpenPageLink extends Command {
  OpenPageLink(this.url)
    : super(
        title: 'Open page link',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
      );

  final String url;

  /// Returns a [PlotLink] if [url] is an internal Plot URL, or null if external.
  static PlotLink? parse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final appUri = Uri.parse(Env.appBaseUrl);
    if (uri.host != appUri.host) return null;

    final segments = uri.pathSegments;
    if (segments.isEmpty) return null;

    // Skip known non-entity paths
    if (segments.first == 'invite' ||
        segments.first == 'login' ||
        segments.first == 'priorities' ||
        segments.first == 'account') {
      return null;
    }

    if (segments.length >= 2 && segments[1] != 'new') {
      return PlotLink(priorityId: segments[0], threadId: segments[1]);
    }
    return PlotLink(priorityId: segments[0]);
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;

      if (segments.isEmpty) {
        return CommandMessage('Invalid link: $url', isError: true);
      }

      // Handle invitation deep links
      if (segments.first == 'invite' && segments.length >= 2) {
        PendingInvite.token = segments[1];
        context.router.push(InviteRoute(token: segments[1]));
        return const CommandDone();
      }

      // Navigate based on path structure
      if (segments.first == 'priorities') {
        // Navigate to priorities page
        context.router.push(PrioritiesRoute());
      } else if (segments.length == 1) {
        // Navigate to priority page: /priorityId
        context.router.push(PriorityRoute(priorityIdString: segments[0]));
      } else if (segments.length >= 2) {
        // Navigate to nested route: /priorityId/threadId or /priorityId/new
        if (segments[1] == 'new') {
          context.router.push(
            PriorityRoute(
              priorityIdString: segments[0],
              children: [NewThreadRoute()],
            ),
          );
        } else {
          context.router.push(
            PriorityRoute(
              priorityIdString: segments[0],
              children: [ThreadRoute(threadIdString: segments[1])],
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
        title: 'Open copied page link',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.link,
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.keyV,
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
