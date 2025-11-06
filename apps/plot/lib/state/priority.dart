import 'dart:async';

import 'package:rxdart/rxdart.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/list.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/api/agent_api.dart';
import 'logging.dart';

part 'priority_state.dart';

class PriorityBloc extends Cubit<PriorityState> {
  PriorityBloc({required Priority priority, Activity? activity})
    : _subscriptions = [],
      _agendaSubscription = null,
      super(PriorityState(context: priority, activity: activity)) {
    _loadPriority();
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));

    // Reload agenda items with new archived filter
    _loadPriority();
  }

  void updateFilter(List<Tag> filter) {
    log.info('Updating filter to $filter');
    emit(state.copyWith(filter: filter));

    // Reload agenda items with new filter
    _loadPriority();
  }

  void moveAgendaItem(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;

    final items = List<AgendaItem>.from(state.agendaItems);
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);

    emit(state.copyWith(agendaItems: items));
  }

  Future<void> fetchMoreAgendaItems(int first, int count) async {
    if (state.range == null) return;

    // Check if requested range is already within current loaded range
    final currentFirst = state.first;
    final currentLast = state.first + state.agendaItems.length;
    final requestedLast = first + count;

    if (first >= currentFirst && requestedLast <= currentLast) {
      log.fine(
        'Requested range [$first, $requestedLast) already within current range [$currentFirst, $currentLast). Skipping fetch.',
      );
      return;
    }

    // Expand requested range by 15% in both directions
    final buffer = (count * 0.15).ceil();
    final expandedFirst = first - buffer;
    final expandedCount = count + (2 * buffer);

    log.fine(
      'Expanding requested range [$first, ${first + count}) by 15% to [$expandedFirst, ${expandedFirst + expandedCount})',
    );

    final moveStart = state.doneStart
        ? 0
        : expandedFirst - state.first; // negative = need before
    final moveEnd = state.doneEnd
        ? 0
        : expandedFirst -
              state.first +
              expandedCount -
              state.agendaItems.length; // positive = need after

    log.fine(
      'Fetching more agenda items: expandedFirst=$expandedFirst, expandedCount=$expandedCount, moveStart=$moveStart, moveEnd=$moveEnd, doneStart=${state.doneStart}, doneEnd=${state.doneEnd}',
    );

    final currentRange = state.range!;
    final rangeDays = currentRange.duration.inDays;

    Date newStart = moveStart < 0 && state.previous != null
        ? state.previous!
        : currentRange.start;
    Date newEnd = moveEnd > 0 && state.next != null
        ? state.next!
        : currentRange.end;

    if (moveStart > 0 || !state.doneStart) {
      final moveDays = (rangeDays * (moveStart / state.agendaItems.length))
          .floor();
      newStart = newStart.addDays(moveDays);
    }

    if (moveEnd > 0 || !state.doneEnd) {
      final moveDays = (rangeDays * (moveEnd / state.agendaItems.length))
          .ceil();
      newEnd = newEnd.addDays(moveDays);
    }

    final newRange = CustomBoundedDateRange(newStart, newEnd);
    log.fine(
      'Expanding range from ${currentRange.start}-${currentRange.end} to ${newRange.start}-${newRange.end}',
    );
    await _loadSchedule(newRange);
  }

  @override
  Future<void> close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _agendaSubscription?.cancel();
    return super.close();
  }

  PriorityId get currentId => state.context.id;

  void setPriority(Priority newPriority) {
    if (state.context.id == newPriority.id) return;

    log.info(
      'Updating priority from ${state.context.title} to ${newPriority.title}',
    );

    // Cancel existing subscriptions
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    _agendaSubscription?.cancel();

    // Update state with new priority
    emit(
      state.copyWith(
        context: newPriority,
        draft: Activity(priority: newPriority, draft: true),
      ),
    );

    // Reload with new priority
    _loadPriority();
  }

  void setActivity(Activity activity) {
    if (state.activity == activity) return;
    emit(state.copyWith(activity: activity));
  }

  void _loadPriority() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.add(
      Priority.watchOne(state.context.id).listen((priority) {
        log.fine('Priority updated');
        emit(state.copyWith(context: priority));
      }),
    );
    if (state.activity != null) {
      _loadActivity(state.activity!);
    }

    // Load agents for the priority
    _loadAgents();

    _loadSchedule(
      state.range ??
          CustomBoundedDateRange(
            Date.today()
                .toDateTime()
                .subtract(const Duration(days: 14))
                .toDate(),
            Date.today().toDateTime().add(const Duration(days: 14)).toDate(),
          ),
      firstDate: Date.today(),
    );
  }

  Future<void> _loadAgents() async {
    try {
      final agents = await AgentApi.getAgentsForPriority(state.context);
      log.info(
        'Loaded ${agents.length} agents for priority ${state.context.title}',
      );
      emit(state.copyWith(agents: agents));
    } catch (e, t) {
      log.warning('Failed to load agents for priority', e, t);
    }
  }

  /// Public method to reload agents - can be called from actions
  Future<void> reloadAgents() async {
    await _loadAgents();
  }

  void _loadActivity(Activity activity) {
    // Watch the activity
    _subscriptions.add(
      Activity.watchOne(activity.id).listen((watchedActivity) {
        log.fine('Activity updated');
        emit(state.copyWith(activity: watchedActivity));
      }),
    );
  }

  Future<void> save(Activity activity) async {
    await activity.save();
  }

  Future<void> add(Activity activity) async {
    emit(
      state.copyWith(
        // Create a new draft
        draft: Activity(priority: state.context, draft: true),
      ),
    );
    activity = activity.copyWith(draft: false);
    await activity.save();
  }

  Future<void> _loadSchedule(BoundedDateRange range, {Date? firstDate}) {
    log.fine('Loading schedule (${range.start} to ${range.end})');
    _agendaSubscription?.cancel();

    // Ensure the new range overlaps with the previous one by at least one day
    // Find the first and last DateAgendaItem in the current agenda items
    var overlappingIndex =
        state.range == null || range.start == state.range?.start
        ? -1
        : state.agendaItems.indexWhere(
            (item) => item.iff(date: (date) => true) == true,
          );
    Date? overlappingDate;
    if (overlappingIndex != -1) {
      overlappingDate = state.agendaItems[overlappingIndex].iff(
        date: (date) => date,
      );
      if (overlappingDate != null && !range.includes(overlappingDate)) {
        if (overlappingDate >= range.end) {
          log.fine('Extending $range to include $overlappingDate');
          // If the new range ends before the old range, extend it to overlap by one day
          range = CustomBoundedDateRange(
            range.start,
            overlappingDate.addDays(1),
          );
        } else {
          overlappingIndex = state.agendaItems.lastIndexWhere(
            (item) => item.iff(date: (date) => true) == true,
          );
          overlappingDate = state.agendaItems[overlappingIndex].iff(
            date: (date) => date,
          );
          if (overlappingDate != null && !range.includes(overlappingDate)) {
            log.fine('Extending $range to include $overlappingDate');
            // If the new range starts after the old range, extend it to overlap by one day
            range = CustomBoundedDateRange(overlappingDate, range.end);
          }
        }
      }
    }
    log.fine(
      'Range: ${range.start} to ${range.end}, overlappingIndex: $overlappingIndex, overlappingDate: $overlappingDate',
    );

    log.fine(
      'Getting activities for priprity ${state.context.id} in range $range',
    );

    // Create a completer to signal when the first result arrives
    final completer = Completer<void>();

    _agendaSubscription =
        Schedule.watch(
          range,
          context: state.context,
          deleted: state.showArchived,
          filter: state.filter.isNotEmpty ? state.filter : null,
        ).debounceTime(const Duration(milliseconds: 100)).listen((schedule) {
          // Calculate the new first index based on date overlap
          int first = state.first;
          if (overlappingIndex != -1) {
            final newScheduleItems = PriorityState._makeAgenda(
              schedule.days,
              context: state.context,
            );
            final newIndex = newScheduleItems.indexWhere(
              (item) => item.when(
                date: (date) => date == overlappingDate,
                priority: (priority) => false,
                activity: (activity) => false,
              ),
            );
            log.fine(
              'First was $first, overlappingIndex is $overlappingIndex, newIndex is $newIndex newFirst = ${first + overlappingIndex - newIndex}',
            );
            if (newIndex != -1) {
              first += overlappingIndex - newIndex;
            }
            // The listener may trigger multiple times, but we only want to adjust first once
            overlappingIndex = -1;
          }

          log.fine(
            'Schedule updated (${range.start} to ${range.end}, first=$first, count=${schedule.days.length}, previous=${schedule.previous}, next=${schedule.next})',
          );

          emit(
            state.copyWith(
              range: range,
              schedule: schedule.days,
              first: first,
              firstDate: firstDate,
              previous: Value(schedule.previous),
              next: Value(schedule.next),
            ),
          );

          // Complete the future on first result
          if (!completer.isCompleted) {
            completer.complete();
          }
        });

    return completer.future;
  }

  final List<StreamSubscription<void>> _subscriptions;
  StreamSubscription<void>? _agendaSubscription;
}

class PriorityBlocProvider extends StatefulWidget {
  const PriorityBlocProvider({
    this.priorityId,
    this.activityId,
    this.priority,
    required this.child,
    super.key,
  });

  final PriorityId? priorityId;
  final ActivityId? activityId;
  final Priority? priority;
  final Widget child;

  @override
  PriorityBlocProviderState createState() => PriorityBlocProviderState();
}

class PriorityBlocProviderState extends State<PriorityBlocProvider> {
  late Future<PriorityBloc> _bloc;

  @override
  void initState() {
    super.initState();
    _bloc =
        (widget.priority != null
                ? Future.value(widget.priority!)
                : widget.priorityId != null
                ? Priority.getOne(widget.priorityId!)
                : widget.activityId != null
                ? Activity.getOne(
                    widget.activityId!,
                  ).then((activity) => activity.priority)
                : Future<Priority>.error(
                    'Either priorityId or activityId must be provided',
                  ))
            .then((priority) {
              return PriorityBloc(priority: priority);
            });
  }

  @override
  void didUpdateWidget(PriorityBlocProvider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.priority != null && widget.priority != oldWidget.priority) {
      _bloc.then((bloc) {
        final priority = widget.priority;
        if (priority == null) return;
        bloc.setPriority(priority);
      });
    } else if (widget.priorityId != null &&
        widget.priorityId != oldWidget.priorityId) {
      _bloc.then((bloc) async {
        final priority = await Priority.getOne(widget.priorityId!);
        bloc.setPriority(priority);
      });
    }
  }

  @override
  void dispose() {
    _bloc.then((bloc) => bloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _bloc,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const LoadingPage();
        }
        return BlocProvider.value(value: snapshot.data!, child: widget.child);
      },
    );
  }
}
