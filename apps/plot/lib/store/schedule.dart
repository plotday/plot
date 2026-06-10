import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/util/async.dart';
import 'store.dart';

class ScheduledDay extends Equatable {
  static Stream<ScheduledDay> watchToday() {
    return Date.current().switchMap((today) => _watchToday(today));
  }

  static Stream<ScheduledDay> _watchToday(
    Date today, {
    Priority? context,
    bool? archived = false,
    List<Tag>? filter,
    String? search,
  }) {
    return Rx.combineLatest2(
      // Events only (same flags as the agenda's events stream). The default
      // `includeUnscheduled: true` admitted EVERY unscheduled thread, so this
      // global watch hydrated and mapped the entire threads table (~5.6k join
      // rows) on every table write — the single biggest work unit competing
      // for the SQLite connection during a focus switch. Every consumer of
      // [ScheduledDay] only reads [scheduled] (timed, non-todo events), so
      // the unscheduled rows were fetched just to be filtered out.
      Thread.watch(
        range: today.toDateRange(),
        priorityPath: context?.path,
        archived: archived,
        filter: filter,
        search: search,
        includeUnscheduled: false,
        eventsOnly: true,
      ).map((result) => result.threads),
      Priority.watchDefault(),
      (List<Thread> allThreads, Priority defaultPriority) =>
          (allThreads, defaultPriority),
    ).transform(
      ExpiringStreamTransformer((result) {
        final allThreads = result.$1;
        final defaultPriority = result.$2;
        final now = Time.now();
        final currentEvent = allThreads.any(
          (a) => a.at?.includes(now) == true,
        );
        DateTime? expiry;
        if (currentEvent) {
          // Expire every minute on the minute
          expiry = now + Duration(seconds: 60 - now.second);
        } else {
          // Find the earliest event start or end following now (including boundary moments)
          expiry = allThreads.fold(null, (DateTime? next, Thread a) {
            // Check event start (after now or at same moment for boundary)
            if (a.at?.start != null &&
                (a.at!.start!.isAfter(now) ||
                    a.at!.start!.isAtSameMomentAs(now)) &&
                (next == null || next.isAfter(a.at!.start!))) {
              return a.at!.start;
            }
            // Check event end (after now or at same moment for boundary)
            if (a.at?.end != null &&
                (a.at!.end!.isAfter(now) || a.at!.end!.isAtSameMomentAs(now)) &&
                (next == null || next.isAfter(a.at!.end!))) {
              return a.at!.end;
            }
            return next;
          });
        }

        List<Thread> dayThreads = [];
        for (final thread in allThreads) {
          if (thread.agendaAt.toDate() == today) {
            if (context == null) {
              dayThreads.add(thread);
            } else {
              final threadPath = thread.priority.path;
              if (threadPath == context.path ||
                  threadPath.isChild(context.path)) {
                dayThreads.add(thread);
              }
            }
          }
        }

        return ExpiringResult(
          value: ScheduledDay._(
            date: today,
            threads: dayThreads,
            defaultPriority: defaultPriority,
          ),
          expiry: expiry,
        );
      }),
    );
  }

  const ScheduledDay._({
    required this.date,
    required this.threads,
    // defaultPriority parameter kept for backward compatibility but no longer used
    // since gaps are now computed in PriorityState._makeAgenda
    Priority? defaultPriority,
  });

  final Date date;
  final List<Thread> threads;

  /// Activities with time-based schedules (excludes todos) and link schedule instances.
  List<Thread> get scheduled => List.unmodifiable(
    threads.where((a) => (a.at != null && !a.todo) || a.isLinkScheduleInstance),
  );

  /// Activities without time-based schedules, plus all todos (excludes link schedule instances).
  List<Thread> get unscheduled => List.unmodifiable(
    threads.where((a) => (a.at == null || a.todo) && !a.isLinkScheduleInstance),
  );

  Thread getAt(DateTime time) {
    return scheduled.firstWhere((e) => e.at?.includes(time) == true);
  }

  @override
  List<Object> get props => [date, scheduled, unscheduled];
}
