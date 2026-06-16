import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/env.dart';
import 'package:plot/page/invite.dart';
import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/shortcut.dart';
import 'command.dart';
import 'logging.dart';

/// Copies the thread's canonical, globally shareable `/t/:threadId` URL to the
/// clipboard.
///
/// Lives on the thread menu (not the global settings menu) because only thread
/// URLs are shareable — a priority/page URL resolves differently per user. The
/// thread is passed in directly so the link is correct on every platform,
/// including single-panel mobile where there's no on-screen address bar.
class CopyThreadLink extends Command {
  CopyThreadLink(this.thread)
    : super(
        title: 'Copy link',
        eventObject: EventObject.navigation,
        eventAction: EventAction.clicked,
        icon: FontAwesomeIcons.link,
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.keyC,
          shift: true,
        ),
      );

  final Thread thread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final fullUrl = '${Env.appBaseUrl}/t/${thread.id.toShortString()}';
      await Clipboard.setData(ClipboardData(text: fullUrl));
      return CommandMessage('Link copied to clipboard');
    } catch (e, t) {
      log.warning("Copy thread link failed", e, t);
      return CommandMessage('Failed to copy link', isError: true);
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
  ///
  /// Accepts both the canonical stage-8 forms (`/p/:priorityId`,
  /// `/t/:threadId`) and the legacy `/:priorityId[/:threadId]` form for
  /// backwards compatibility with links copied before the routing rewrite.
  static PlotLink? parse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final appUri = Uri.parse(Env.appBaseUrl);
    if (uri.host != appUri.host) return null;

    final segments = uri.pathSegments;
    if (segments.isEmpty) return null;

    // Canonical priority URL: /p/:priorityId[/:threadId]
    if (segments.first == 'p') {
      if (segments.length < 2) return null;
      if (segments.length >= 3 && segments[2] != 'new') {
        return PlotLink(priorityId: segments[1], threadId: segments[2]);
      }
      return PlotLink(priorityId: segments[1]);
    }
    // Canonical standalone thread URL: /t/:threadId
    if (segments.first == 't') {
      if (segments.length < 2) return null;
      return PlotLink(threadId: segments[1]);
    }

    // Skip known non-entity paths
    if (segments.first == 'invite' ||
        segments.first == 'login' ||
        segments.first == 'priorities' ||
        segments.first == 'account') {
      return null;
    }

    // Legacy /:priorityId[/:threadId]
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

      if (segments.first == 'priorities') {
        context.router.push(PrioritiesRoute());
        return const CommandDone();
      }

      // Canonical /p/:priorityId[/:threadId | /new]
      if (segments.first == 'p' && segments.length >= 2) {
        final priorityIdString = segments[1];
        if (segments.length >= 3 && segments[2] == 'new') {
          context.router.push(
            PriorityRoute(
              priorityIdString: priorityIdString,
              children: [NewThreadRoute()],
            ),
          );
        } else if (segments.length >= 3) {
          context.router.push(
            PriorityRoute(
              priorityIdString: priorityIdString,
              children: [ThreadRoute(threadIdString: segments[2])],
            ),
          );
        } else {
          // Naked /p/:id — in multi-panel mode also push NewThreadRoute so
          // the right panel lands on NewThreadPage instead of flashing the
          // PriorityOnlyPage→LoadingPage redirect.
          final multi = context.read<LayoutBloc>().state.multiPanel;
          context.router.push(
            PriorityRoute(
              priorityIdString: priorityIdString,
              children: multi ? [NewThreadRoute()] : null,
            ),
          );
        }
        return const CommandDone();
      }

      // Canonical /t/:threadId — lookup route resolves priority
      if (segments.first == 't' && segments.length >= 2) {
        context.router.push(ThreadLookupRoute(threadIdString: segments[1]));
        return const CommandDone();
      }

      // Legacy /:priorityId[/:threadId | /new]
      if (segments.length == 1) {
        final multi = context.read<LayoutBloc>().state.multiPanel;
        context.router.push(
          PriorityRoute(
            priorityIdString: segments[0],
            children: multi ? [NewThreadRoute()] : null,
          ),
        );
      } else if (segments.length >= 2) {
        if (segments[1] == 'new') {
          context.router.push(
            PriorityRoute(
              priorityIdString: segments[0],
              children: [NewThreadRoute()],
            ),
          );
        } else {
          context.router.push(
            ThreadLookupRoute(threadIdString: segments[1]),
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
