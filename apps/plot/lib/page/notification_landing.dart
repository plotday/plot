import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'package:plot/state/activity_section.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/store/store.dart';

final Logger _log = Logger('plot.page.notification_landing');

/// Landing page for a multi-thread notification tap. Shows a [LoadingPage]
/// while it prefetches any of the notification's thread rows that aren't
/// yet local, then replaces the stack with the LCA priority's activity
/// feed and signals (via [PendingActivityFeedView.openCatchUpTab]) that
/// the priority should open on the "Catch up" tab.
///
/// Used only by the notification-tap flow. The single-thread case still
/// goes through [ThreadLookupRoute].
@RoutePage(name: "NotificationLandingRoute")
class NotificationLandingPage extends StatefulWidget {
  NotificationLandingPage({
    required this.priorityIdString,
    required this.threadIdsString,
  }) : super(key: ValueKey('$priorityIdString:$threadIdsString'));

  /// Short-encoded LCA priority id (base58).
  final String priorityIdString;

  /// Comma-separated raw UUID thread ids covered by the notification.
  final String threadIdsString;

  @override
  State<NotificationLandingPage> createState() =>
      _NotificationLandingPageState();
}

class _NotificationLandingPageState extends State<NotificationLandingPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    if (!mounted) return;

    final threadIds = widget.threadIdsString
        .split(',')
        .where((s) => s.isNotEmpty)
        .map((s) {
          try {
            return Uuid.fromString(s);
          } catch (_) {
            return null;
          }
        })
        .whereType<ThreadId>()
        .toList();

    if (threadIds.isNotEmpty) {
      final missing = await _missingThreadIds(threadIds);
      if (missing.isNotEmpty) {
        try {
          await Thread.prefetchByIds(
            missing,
          ).timeout(const Duration(seconds: 6));
        } catch (e, stackTrace) {
          _log.warning(
            'Prefetch failed for ${missing.length} threads',
            e,
            stackTrace,
          );
        }
      }
    }

    if (!mounted) return;
    PendingActivityFeedView.openCatchUpTab = true;
    final multi = context.read<LayoutBloc>().state.multiPanel;
    context.router.replaceAll([
      PriorityRoute(
        priorityIdString: widget.priorityIdString,
        children: multi ? [NewThreadRoute()] : null,
      ),
    ]);
  }

  Future<List<ThreadId>> _missingThreadIds(List<ThreadId> ids) async {
    final missing = <ThreadId>[];
    for (final id in ids) {
      try {
        await Thread.getOne(id);
      } catch (_) {
        missing.add(id);
      }
    }
    return missing;
  }

  @override
  Widget build(BuildContext context) => const LoadingPage();
}
