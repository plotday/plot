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
  static final Map<Activity?, List<List<ScheduledEvent>>> _cache = {};
  static final Map<Activity?, Map<TimeDirection, DateTime>> _last = {};
  static final Map<_FetchParams, Future<List<ScheduledEvent>>> _loading = {};
  static const int _pageSize = 50;

  static List<ScheduledEvent>? _getList(Activity? activity, DateTime anchor,
      {bool createIfNeeded = false}) {
    if (_cache[activity] == null) _cache[activity] = [];
    for (final list in _cache[activity]!) {
      // This works, because we always fetch beyond the next anchor
      if (list.isNotEmpty &&
          Interval(list.first.at.start, list.last.at.start).includes(anchor)) {
        print("Returning list with ${list.length} items");
        return list;
      }
    }
    if (!createIfNeeded) return null;
    print("Creating new list for $activity at $anchor");
    final newList = <ScheduledEvent>[];
    _cache[activity]!.add(newList);
    return newList;
  }

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
                ? "(,${anchor.toDb()})"
                : "[${anchor.toDb()},)");
    if (activity != null) {
      query = query.eq('activity_id', activity.id!);
    }
    final response = await query
        .order('at', ascending: direction == TimeDirection.ascending)
        .limit(_pageSize);
    final items =
        response.map((event) => ScheduledEvent.fromJson(event)).toList();
    if (items.length < _pageSize) {
      _last[activity] ??= {};
      _last[activity]![direction] = items.isNotEmpty
          ? direction == TimeDirection.descending
              ? items.first.at.start
              : items.last.at.start
          : anchor;
    }

    print("_getList 1");
    final list = _getList(activity, anchor, createIfNeeded: true)!;
    print("_getList 2");
    if (list.isNotEmpty) {
      final demarcation = items.indexWhere((event) =>
          event.id ==
          (direction == TimeDirection.descending
              ? list.first.id
              : list.last.id));
      print("First: ${list.first.id}, last: ${list.last.id}");
      if (demarcation >= 0) {
        print("Removing ${demarcation + 1} items");
        items.removeRange(0, demarcation + 1);
      }
    }
    if (direction == TimeDirection.descending) {
      print(
          "Inserting (reverse): ${items.reversed.map((item) => item.id).join(', ')}");
      list.insertAll(0, items.reversed);
    } else {
      print("Inserting: ${items.map((item) => item.id).join(', ')}");
      list.addAll(items);
    }
    // TODO: merge lists

    return list;
  }

  static Future<List<ScheduledEvent>> _fetch(DateTime anchor,
      {TimeDirection direction = TimeDirection.ascending,
      Activity? activity}) async {
    final last = (_last[activity] ?? {})[direction];
    if (last != null &&
        (direction == TimeDirection.descending
            ? anchor.isSameOrBefore(last)
            : anchor.isSameOrAfter(last))) {
      return [];
    }

    final params = _FetchParams(anchor, direction, activity);
    var other = _loading[params];
    if (other == null) {
      other = _fetchImpl(anchor, direction: direction, activity: activity);
      _loading[params] = other;
    }
    return await other;
  }

  static Future<GroupedEvents> list(DateTime anchor,
      {TimeHorizon horizon = TimeHorizon.day,
      TimeDirection direction = TimeDirection.ascending,
      Activity? activity}) async {
    anchor = anchor.startOfDay;
    final movement = Duration(
        days: (horizon == TimeHorizon.week ? 7 : 1) *
            (direction == TimeDirection.descending ? -1 : 1));

    var list = _getList(activity, anchor);

    // attempt up to three fetches to reach the next horizon
    for (var i = 0; i < 3; i++) {
      final horizons = list == null || list.isEmpty
          ? 0
          : (anchor.differenceInDays(direction == TimeDirection.descending
                      ? list.first.at.start.addSeconds(1)
                      : list.last.at.start))
                  .abs() %
              (movement.inDays).abs();
      if (horizons > 0) {
        break;
      }

      var fetchAnchor = anchor;
      if (list?.isNotEmpty ?? false) {
        fetchAnchor = direction == TimeDirection.descending
            ? list!.first.at.start
            : list!.last.at.start;
      }
      list =
          await _fetch(fetchAnchor, direction: direction, activity: activity);
    }

    Map<DateTime, List<ScheduledEvent>> groupedEvents = {};
    DateTime? nextAnchor;
    var numItems = 0;
    for (var h =
            horizon == TimeHorizon.week ? Time.week(anchor) : Time.day(anchor);
        numItems < _pageSize;
        h = direction == TimeDirection.descending ? h.previous : h.next) {
      var groupedList = <ScheduledEvent>[];
      var iterator = list?.where((event) =>
          (direction == TimeDirection.descending ? h.previous : h)
              .includes(event.at.start));
      if (iterator != null) {
        groupedList = iterator.toList();
      }
      numItems += groupedList.isNotEmpty ? groupedList.length : 1;
      groupedEvents[(direction == TimeDirection.descending ? h.previous : h)
          .start] = groupedList;
      nextAnchor = h.start;
    }

    if (direction == TimeDirection.descending) {
      print("Listing $horizon $direction from $anchor");
      print("Next anchor: $nextAnchor");
    }
    return GroupedEvents(events: groupedEvents, nextAnchor: nextAnchor);
  }

  static Future<List<ScheduledEvent>> today() async {
    final today = Time.today().start;
    // Could optimize to only return one day
    return (await list(today)).events[today] ?? [];
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
