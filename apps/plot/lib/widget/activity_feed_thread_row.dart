import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/thread.dart';

/// A single activity-feed row that resolves a representative occurrence for the
/// thread before rendering.
///
/// Calendar-event threads file the series; the row should display a specific
/// occurrence (its date, RSVP, and event timing). This widget wraps
/// [ThreadWidget] in a [FutureBuilder] over
/// [PriorityBloc.loadRepresentativeForFeed] so event rows show the right
/// occurrence and `showEventTiming` reflects whether one was found. Non-event
/// threads resolve a null representative and render unchanged.
///
/// Shared between the activity feed ([PriorityPage]) and the global Search tab
/// so both surface identical, occurrence-aware rows. Requires an ancestor
/// [PriorityBloc] (via [BlocProvider]/[PriorityBlocProvider]).
class ActivityFeedThreadRow extends StatefulWidget {
  const ActivityFeedThreadRow({
    super.key,
    required this.baseThread,
    required this.selected,
    required this.now,
    required this.focusNode,
    required this.priorityContext,
    this.isAssociated = false,
    this.isSearch = false,
    this.onActivate,
  });

  final Thread baseThread;
  final bool selected;
  final bool now;
  final FocusNode focusNode;
  final Priority priorityContext;
  final bool isAssociated;
  final bool isSearch;

  /// Overrides the row's tap-to-open behaviour. Forwarded to [ThreadWidget].
  /// When null, the default [ChangeCurrentThread] navigation runs (the
  /// behaviour the priority feed relies on).
  final VoidCallback? onActivate;

  @override
  State<ActivityFeedThreadRow> createState() => _ActivityFeedThreadRowState();
}

class _ActivityFeedThreadRowState extends State<ActivityFeedThreadRow> {
  late Future<Thread?> _representative;

  @override
  void initState() {
    super.initState();
    _representative = context.read<PriorityBloc>().loadRepresentativeForFeed(
      widget.baseThread,
    );
  }

  @override
  void didUpdateWidget(covariant ActivityFeedThreadRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.baseThread.id != widget.baseThread.id ||
        oldWidget.baseThread.scheduleId != widget.baseThread.scheduleId ||
        oldWidget.baseThread.currentUserRsvp !=
            widget.baseThread.currentUserRsvp) {
      _representative = context.read<PriorityBloc>().loadRepresentativeForFeed(
        widget.baseThread,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Thread?>(
      future: _representative,
      builder: (context, snapshot) {
        final rep = snapshot.data;
        // Compose the live baseThread with the cached representative's
        // picked schedule + flags so the row reflects up-to-date sync
        // state (unread, title, tags, …) instead of the snapshot taken
        // when the representative was resolved. See
        // PriorityBloc._representativeCache for why we cache.
        final display = rep != null
            ? widget.baseThread.withRepresentativeFrom(rep)
            : widget.baseThread;
        // Key intentionally excludes the resolved scheduleId — including
        // it would change identity once the Future resolves and force
        // every ThreadWidget to remount, dropping focus and re-running
        // layout.
        return ThreadWidget(
          key: ValueKey('feed_activitywidget_${widget.baseThread.id}'),
          activity: display,
          selected: widget.selected,
          now: widget.now,
          focusNode: widget.focusNode,
          context: widget.priorityContext,
          showSubPriority: true,
          isSearch: widget.isSearch,
          showEventTiming: rep != null,
          isAssociated: widget.isAssociated,
          onActivate: widget.onActivate,
        );
      },
    );
  }
}
