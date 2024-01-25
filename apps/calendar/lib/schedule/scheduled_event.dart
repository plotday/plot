import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util/time.dart';
import '../priority/activity.dart';

final supabase = Supabase.instance.client;

class GroupedEvents {
  const GroupedEvents({required this.events, this.nextAnchor});
  final Map<DateTime, List<ScheduledEvent>> events;
  final DateTime? nextAnchor;
}

class _FetchParams extends Equatable {
  const _FetchParams(this.anchor, this.direction, this.activity);

  final DateTime anchor;
  final TimeDirection direction;
  final Activity? activity;

  @override
  List<Object> get props => [anchor, direction, activity ?? ''];
}

class ScheduledEvent extends Equatable {
  // All (null) or specific activities
  // Contiguous lists in ascending order
  static final Map<Activity?, Map<DateTime, List<ScheduledEvent>>> _cache = {};
  static final Map<Activity?, Map<TimeDirection, DateTime>> _last = {};
  static final Map<_FetchParams, Future<List<ScheduledEvent>>> _loading = {};
  static const int _pageSize = 50;

  static Future<List<ScheduledEvent>> _fetchImpl(DateTime anchor,
      {TimeDirection direction = TimeDirection.ascending,
      Activity? activity}) async {
    var query = supabase
        .from('event_x')
        .select()
        .eq('user_id', supabase.auth.currentUser!.id)
        .overlaps(
            'at',
            direction == TimeDirection.descending
                ? "(,${(anchor + const Duration(days: 1)).toDb()})"
                : "[${anchor.toDb()},)");
    if (activity != null) {
      query = query.eq('activity_id', activity.id!);
    }
    final response = await query
        .order('at', ascending: direction == TimeDirection.ascending)
        .limit(_pageSize);
    var items =
        response.map((event) => ScheduledEvent.fromJson(event)).toList();
    print("Fetched ${anchor.toDb()} $direction: ${items.first.at.start}");

    if (items.length < _pageSize) {
      _last[activity] ??= {};
      _last[activity]![direction] ??=
          items.isEmpty ? anchor : items.last.at.start;
      print("LAST: ${_last[activity]![direction]} (${items.length})");
    }

    // Remove any partial days
    if (items.isNotEmpty) {
      final removeFrom = items
          .indexWhere((event) => event.at.start.isSameDay(items.last.at.start));
      items.removeRange(removeFrom, items.length);
    }
    if (direction == TimeDirection.descending) {
      items = items.toList().reversed.toList();
    }
    print("Adding ${items.length} items");
    _cache[activity] ??= {};
    for (var day = Time.day(anchor);
        direction == TimeDirection.descending
            ? day.start.isAfter(items.first.at.start)
            : day.end.isBefore(items.last.at.start);
        day = direction == TimeDirection.descending ? day.previous : day.next) {
      _cache[activity]![day.start] =
          items.where((event) => day.includes(event.at.start)).toList();
    }
    return _cache[activity]?[anchor] ?? [];
  }

  static Future<List<ScheduledEvent>> _fetch(DateTime anchor,
      {TimeDirection direction = TimeDirection.ascending,
      Activity? activity}) async {
    final params = _FetchParams(anchor, direction, activity);
    var other = _loading[params];
    if (other == null) {
      other = _fetchImpl(anchor, direction: direction, activity: activity);
      _loading[params] = other;
    }
    return await other;
  }

  static bool _isDone(
      Activity? activity, DateTime anchor, TimeDirection direction) {
    final last = (_last[activity] ?? {})[direction];
    return last != null &&
        (direction == TimeDirection.descending
            ? anchor.isSameOrBefore(last)
            : anchor.isSameOrAfter(last));
  }

  static Future<List<ScheduledEvent>> list(DateTime anchor,
      {TimeHorizon horizon = TimeHorizon.day,
      TimeDirection direction = TimeDirection.ascending,
      Activity? activity}) async {
    anchor = anchor.startOfDay;

    if (_isDone(activity, anchor, direction)) {
      return [];
    }

    final items = _cache[activity]?[anchor];
    if (items != null) {
      return items;
    }

    // TODO : handle week
    return await _fetch(anchor, direction: direction, activity: activity);
    //
    // if (_isDone(activity, anchor, direction)) {
    //   print("No more!");
    //   return const GroupedEvents(events: {}, nextAnchor: null);
    // }
    //
    // final movement = Duration(days: horizon == TimeHorizon.week ? 7 : 1) *
    //     (direction == TimeDirection.descending ? -1 : 1);
    //
    // // attempt up to three fetches to reach the next horizon
    // List<ScheduledEvent> list = [];
    // var fetchAnchor = anchor;
    // for (var i = 0; i < 3; i++) {
    //   list =
    //       await _fetch(fetchAnchor, direction: direction, activity: activity);
    //   final horizons = list.isEmpty
    //       ? 0
    //       : (anchor
    //               .differenceInDays(direction == TimeDirection.descending
    //                   ? list.first.at.start.addSeconds(1)
    //                   : list.last.at.start)
    //               .abs() /
    //           movement.inDays.abs());
    //   if (horizons > 0) {
    //     break;
    //   }
    //
    //   if (list.isNotEmpty) {
    //     fetchAnchor = _getHead(list, direction)!.at.start;
    //   }
    // }
    //
    // if (list.isEmpty) {
    //   throw Exception("Could not get more events");
    // }
    //
    // Map<DateTime, List<ScheduledEvent>> groupedEvents = {};
    // DateTime? nextAnchor;
    // for (var h =
    //         horizon == TimeHorizon.week ? Time.week(anchor) : Time.day(anchor);
    //     direction == TimeDirection.descending
    //         ? list.first.at.start.isBefore(h.previous.start)
    //         : list.last.at.start.isSameOrAfter(h.next.start);
    //     h = direction == TimeDirection.descending ? h.previous : h.next) {
    //   final h2 = direction == TimeDirection.descending ? h.previous : h;
    //   groupedEvents[h2.start] =
    //       list.where((event) => (h2).includes(event.at.start)).toList();
    //   nextAnchor = h2.start;
    // }
    //
    // print(
    //     "Returning $horizon $direction from $anchor to $nextAnchor (${groupedEvents.keys.length})");
    // if (groupedEvents.keys.length == 0) {
    //   throw new Exception("no items");
    // }
    // return GroupedEvents(events: groupedEvents, nextAnchor: nextAnchor);
  }

  static Future<List<ScheduledEvent>> today() async {
    final today = Time.today().start;
    // Could optimize to only return one day
    return await list(today);
  }

  static Future<List<ScheduledEvent>> current() async {
    final all = await today();
    final current = all.where((ScheduledEvent event) {
      return event.at.includes(DateTime.now());
    }).toList();
    return Future.value(current);
  }

  static Future<List<ScheduledEvent>> next() async {
    final all = await today();
    final now = DateTime.now();
    var next = all.where((ScheduledEvent event) {
      return event.at.start.isAfter(now);
    }).toList();
    if (next.isNotEmpty) {
      next = all.where((ScheduledEvent event) {
        return event.at.start == next.first.at.start;
      }).toList();
    }
    return Future.value(next);
  }

  ScheduledEvent.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        name = json['name'] as String,
        at = Time.interval(json['at'] as String),
        _activityId = json['activity_id'] as int?;

  final int? id;
  final String name;
  final Interval at;
  get activity => _activityId == null ? null : Activity.get(_activityId);

  final int? _activityId;

  @override
  List<Object> get props => [id ?? 0, name, at, _activityId ?? 0];
}

class ScheduledDay extends Equatable {
  const ScheduledDay(this.day, this.events);

  final Interval day;
  final List<ScheduledEvent> events;

  @override
  List<Object> get props => [day, events];
}
