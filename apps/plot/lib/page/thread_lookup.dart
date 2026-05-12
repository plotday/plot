import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'package:plot/store/store.dart';

final Logger _log = Logger('plot.page.thread_lookup');

/// Standalone thread view entry point — resolves a thread id to its
/// priority filing and navigates to the canonical
/// `/p/:priorityId/:threadId` form.
///
/// Used to back the shareable `/t/:threadId` URL form. The page itself
/// never renders interactive UI: as soon as the thread row is loaded it
/// replaces the navigation stack with the nested PriorityRoute +
/// ThreadRoute pair so the user lands in their usual priority layout.
@RoutePage(name: "ThreadLookupRoute")
class ThreadLookupPage extends StatefulWidget {
  ThreadLookupPage({@PathParam("threadId") required this.threadIdString})
    : super(key: ValueKey(threadIdString));

  final String threadIdString;

  @override
  State<ThreadLookupPage> createState() => _ThreadLookupPageState();
}

class _ThreadLookupPageState extends State<ThreadLookupPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _redirect());
  }

  Future<void> _redirect() async {
    if (!mounted) return;
    final threadId = ThreadId.fromShortString(widget.threadIdString);

    Thread? thread = await _loadThread(threadId);

    // Not in the local store yet — common when arriving from a notification
    // tap, since the system notification can be shown before the next
    // cursor pull lands. Fetch the row directly and try again. This is a
    // bounded, by-id call that does not advance any sync cursor.
    if (thread == null) {
      try {
        await Thread.prefetchByIds([
          threadId,
        ]).timeout(const Duration(seconds: 6));
      } catch (e, stackTrace) {
        _log.warning(
          'Prefetch failed for ${widget.threadIdString}',
          e,
          stackTrace,
        );
      }
      if (!mounted) return;
      thread = await _loadThread(threadId);
    }

    if (!mounted) return;
    if (thread != null) {
      context.router.replaceAll([
        PriorityRoute(
          priorityIdString: thread.priority.id.toShortString(),
          children: [ThreadRoute(threadIdString: widget.threadIdString)],
        ),
      ]);
      return;
    }

    _log.warning('Thread ${widget.threadIdString} not available after prefetch');
    context.router.replaceAll([const RootRoute()]);
  }

  Future<Thread?> _loadThread(ThreadId id) async {
    try {
      return await Thread.getOne(id);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => const LoadingPage();
}
