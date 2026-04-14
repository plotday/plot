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
    try {
      final threadId = ThreadId.fromShortString(widget.threadIdString);
      final thread = await Thread.getOne(threadId);
      if (!mounted) return;
      context.router.replaceAll([
        PriorityRoute(
          priorityIdString: thread.priority.id.toShortString(),
          children: [ThreadRoute(threadIdString: widget.threadIdString)],
        ),
      ]);
    } catch (e, stackTrace) {
      _log.warning(
        'Failed to resolve thread ${widget.threadIdString}',
        e,
        stackTrace,
      );
      if (!mounted) return;
      context.router.replaceAll([EmptyShellRoute("Now")()]);
    }
  }

  @override
  Widget build(BuildContext context) => const LoadingPage();
}
