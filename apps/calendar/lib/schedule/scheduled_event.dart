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

class ScheduledEvent extends Equatable {
  // All (null) or specific activities
  // Contiguous lists in ascending order
  static final Map<Activity?, List<List<ScheduledEvent>>> _cache = {};
  static const int _pageSize = 50;

  static List<ScheduledEvent> _getList(Activity? activity, DateTime anchor) {
    if (_cache[activity] == null) _cache[activity] = [];
    for (final list in _cache[activity]!) {
      // This works, because we always fetch beyond the next anchor
      if (list.isNotEmpty &&
          Interval(list.first.at.start, list.last.at.start).includes(anchor)) {
        return list;
      }
    }
    final newList = <ScheduledEvent>[];
    _cache[activity]!.add(newList);
    return newList;
  }

  static Future<List<ScheduledEvent>> _fetch(DateTime anchor,
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
    return response.map((event) => ScheduledEvent.fromJson(event)).toList();
  }

  static Future<GroupedEvents> list(DateTime anchor,
      {TimeHorizon horizon = TimeHorizon.day,
      TimeDirection direction = TimeDirection.ascending,
      Activity? activity}) async {
    anchor = anchor.startOfDay;
    final movement = Duration(
        days: (horizon == TimeHorizon.week ? 7 : 1) *
            (direction == TimeDirection.descending ? -1 : 1));

    final list = _getList(activity, anchor);

    // attempt up to three fetches to reach the next horizon
    DateTime nextAnchor = anchor.add(movement);
    for (var i = 0; i < 3; i++) {
      final horizons = list.isEmpty
          ? 0
          : (anchor.differenceInDays(direction == TimeDirection.descending
                      ? list.first.at.start.addSeconds(1)
                      : list.last.at.start))
                  .abs() %
              (movement.inDays).abs();
      if (horizons > 0) {
        nextAnchor = anchor.add(Duration(days: horizons * movement.inDays));
        break;
      }

      var fetchAnchor = anchor;
      if (list.isNotEmpty) {
        fetchAnchor = direction == TimeDirection.descending
            ? list.first.at.start
            : list.last.at.start;
      }
      final events =
          await _fetch(fetchAnchor, direction: direction, activity: activity);
      if (direction == TimeDirection.descending) {
        var demarcation = events.length - 1;
        if (list.isNotEmpty) {
          demarcation =
              events.lastIndexWhere((event) => event.id == list.first.id);
        }
        if (demarcation > 0) {
          list.insertAll(0, events.sublist(0, demarcation));
        }
      } else {
        var demarcation = 0;
        if (list.isNotEmpty) {
          demarcation = events.indexWhere((event) => event.id == list.last.id);
        }
        if (demarcation + 1 < events.length) {
          list.addAll(events.sublist(demarcation + 1));
        }
      }
    }
    // TODO: merge lists

    Map<DateTime, List<ScheduledEvent>> groupedEvents = {};
    for (var h =
            horizon == TimeHorizon.week ? Time.week(anchor) : Time.day(anchor);
        h.start != nextAnchor;
        h = direction == TimeDirection.descending ? h.previous : h.next) {
      var iterator = list.where((event) =>
          (direction == TimeDirection.descending ? h.previous : h)
              .includes(event.at.start));
      if (direction == TimeDirection.descending) {
        iterator = iterator.toList().reversed;
      }
      groupedEvents[h.start] = iterator.toList();
    }

    print(
        "list: $anchor $direction $nextAnchor (${groupedEvents.keys.join(",")})");
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
