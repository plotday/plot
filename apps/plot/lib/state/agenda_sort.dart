import 'package:plot/store/store.dart';

/// Pure sort helpers for the agenda's block-aware ordering rules.
///
/// These functions are intentionally side-effect-free and free of Bloc /
/// Drift dependencies so they can be unit-tested cheaply.
class AgendaSort {
  AgendaSort._();

  /// Compare two threads inside a single priority block, at moment [moment].
  ///
  /// The rule:
  ///   1. A thread that has reached its scheduled time/date sits above
  ///      threads that haven't (or have no schedule). Among those that
  ///      have reached, the **most-recently-arrived** sits highest
  ///      (DESC by promotion time) — the "stack" semantic.
  ///   2. Threads whose schedule hasn't arrived (or that have no
  ///      schedule) sort by manual fractional order ASC.
  ///   3. Final tiebreak: manual order ASC.
  static int compareThreadsInBlock(Thread a, Thread b, DateTime moment) {
    return comparePure(
      aPromotion: promotionTime(a),
      aOrder: a.order,
      bPromotion: promotionTime(b),
      bOrder: b.order,
      moment: moment,
    );
  }

  /// The moment a thread "arrives" in its block (i.e. when it should
  /// promote to the top per Rule 5 of the agenda spec).
  ///
  ///   - Active todo with `startAt`: that exact instant.
  ///   - Active todo with only `startOn`: start-of-day for that date.
  ///   - Calendar / link event: `at.start` or `on.start`.
  ///   - Anything else (untimed thread): `null` (never promotes).
  static DateTime? promotionTime(Thread t) {
    if (t.todo) {
      // Use todoSortDate; for active todos this is one of:
      //   startOn (start-of-day) | pinnedAfterTime | at.start | on.start
      // It does NOT fall back to createdAt for active todos because
      // `todo` requires startOn or startAt to be set.
      return t.todoSortDate;
    }
    if (t.isLinkScheduleInstance) {
      return t.at?.start ?? t.on?.start?.toDateTime();
    }
    return null;
  }

  /// Lower-level pure variant used by tests — given a promotion time
  /// (or null) and a manual order for each side, return the sort
  /// comparator result.
  ///
  /// Use this when you don't want to construct a full [Thread].
  static int comparePure({
    required DateTime? aPromotion,
    required Order aOrder,
    required DateTime? bPromotion,
    required Order bOrder,
    required DateTime moment,
  }) {
    final aArrivedAt = (aPromotion != null && !aPromotion.isAfter(moment))
        ? aPromotion
        : null;
    final bArrivedAt = (bPromotion != null && !bPromotion.isAfter(moment))
        ? bPromotion
        : null;
    if ((aArrivedAt != null) != (bArrivedAt != null)) {
      return aArrivedAt != null ? -1 : 1;
    }
    if (aArrivedAt != null && bArrivedAt != null) {
      final timeCompare = bArrivedAt.compareTo(aArrivedAt);
      if (timeCompare != 0) return timeCompare;
    }
    return aOrder.compareTo(bOrder);
  }
}
