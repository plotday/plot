import 'package:plot/store/store.dart';

/// Default per-day cap on how many threads a single priority shows in
/// the agenda before the surplus cascades onto the next day. Static for
/// now; a future iteration will read a per-priority configurable value.
const int kAgendaThreadsPerDayPerPriorityDefault = 10;

/// Maximum number of empty days to synthesize beyond the last natural
/// scheduled-day section when the cascade still has overflow to place.
/// Acts as a safety bound; any residual past this limit is dumped onto
/// the last synthesized day so the cap degrades softly instead of
/// looping forever.
const int kAgendaCascadeSynthesisHorizonDays = 14;

/// The maximum number of threads to render for [priority] on a single
/// day in the activity feed. Threads beyond this count cascade onto
/// subsequent days.
int agendaThreadsPerDay(Priority priority) =>
    kAgendaThreadsPerDayPerPriorityDefault;

/// Result of [cascadeActivityFeedByPriority].
typedef ActivityFeedCascadeResult = ({
  List<Thread> active,
  Map<Date, List<Thread>> scheduledByDate,
});

/// Apply the per-priority per-day cap to the activity feed and cascade
/// overflow forward from one day to the next.
///
/// Inputs:
///   - [today]: the date represented by the activity feed's Today section.
///   - [active]: threads natively in the Today section.
///   - [scheduledByDate]: threads natively scheduled for each future day.
///
/// Algorithm: walk the dates in order; for each day, group its current
/// occupants (natives plus anything spilled from earlier days) by
/// `priority.id`. Each group is sorted ASC by `Order` (so under the
/// post-flip `Order.first()` convention the newest threads are at the
/// top of the group), and the first [agendaThreadsPerDay] entries stay
/// on the day. The remainder is carried forward to the next day under
/// the same priority. Trailing empty scheduled-day sections are
/// synthesized as needed (bounded by
/// [kAgendaCascadeSynthesisHorizonDays]).
ActivityFeedCascadeResult cascadeActivityFeedByPriority({
  required Date today,
  required List<Thread> active,
  required Map<Date, List<Thread>> scheduledByDate,
}) {
  final scheduledDates = scheduledByDate.keys
      .where((d) => d > today)
      .toList()
    ..sort();

  final dates = <Date>[today, ...scheduledDates];
  final perDate = <Date, List<Thread>>{
    today: List<Thread>.from(active),
    for (final d in scheduledDates)
      d: List<Thread>.from(scheduledByDate[d] ?? const <Thread>[]),
  };

  var spillover = <PriorityId, List<Thread>>{};
  var i = 0;
  while (i < dates.length) {
    final date = dates[i];
    final byPriority = <PriorityId, List<Thread>>{};
    for (final t in perDate[date] ?? const <Thread>[]) {
      byPriority.putIfAbsent(t.priority.id, () => <Thread>[]).add(t);
    }
    spillover.forEach((pid, threads) {
      byPriority.putIfAbsent(pid, () => <Thread>[]).addAll(threads);
    });
    spillover = <PriorityId, List<Thread>>{};

    final keep = <Thread>[];
    for (final entry in byPriority.entries) {
      final list = entry.value..sort((a, b) => a.order.compareTo(b.order));
      final cap = agendaThreadsPerDay(list.first.priority);
      if (list.length > cap) {
        keep.addAll(list.take(cap));
        spillover[entry.key] = list.skip(cap).toList();
      } else {
        keep.addAll(list);
      }
    }
    perDate[date] = keep;

    final isLast = i == dates.length - 1;
    if (spillover.isNotEmpty && isLast) {
      final synthesizedSoFar = dates.length - (1 + scheduledDates.length);
      if (synthesizedSoFar < kAgendaCascadeSynthesisHorizonDays) {
        final nextDate = date.addDays(1);
        dates.add(nextDate);
        perDate.putIfAbsent(nextDate, () => <Thread>[]);
      } else {
        for (final entry in spillover.entries) {
          perDate[date] = [...perDate[date] ?? const [], ...entry.value];
        }
        spillover = <PriorityId, List<Thread>>{};
      }
    }
    i++;
  }

  final newScheduledByDate = <Date, List<Thread>>{};
  for (final d in dates.skip(1)) {
    final list = perDate[d];
    if (list != null && list.isNotEmpty) newScheduledByDate[d] = list;
  }
  return (
    active: perDate[today] ?? const <Thread>[],
    scheduledByDate: newScheduledByDate,
  );
}
