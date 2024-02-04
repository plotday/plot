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

    if (items.length < _pageSize) {
      _last[activity] ??= {};
      _last[activity]![direction] ??=
          items.isEmpty ? anchor : items.last.at.start;
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

  static Future<List<ScheduledEvent>> getDay(DateTime anchor,
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

    return await _fetch(anchor, direction: direction, activity: activity);
  }

  static Future<Map<DateTime, List<ScheduledEvent>>> list(DateTime anchor,
      {TimeHorizon horizon = TimeHorizon.day,
      TimeDirection direction = TimeDirection.ascending,
      Activity? activity,
      int minHorizons = 10}) async {
    anchor = anchor.startOfDay;

    Map<DateTime, List<ScheduledEvent>> items = {};
    for (var i = 0; i < minHorizons; i++) {
      var day = _cache[activity]?[anchor];
      day ??= await _fetch(anchor, direction: direction, activity: activity);
      items[anchor] = day;
      anchor = direction == TimeDirection.descending
          ? anchor - horizon.duration
          : anchor + horizon.duration;
    }
    return items;
  }

  static Future<List<ScheduledEvent>> today() async {
    return await getDay(Time.today().start);
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

  ScheduledEvent(
      {required this.name, required this.at, this.id, Activity? activity})
      : _activityId = activity?.id;

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
  static const _startOfDay = TimeOfDay(hour: 7, minute: 0);
  static const _endOfDay = TimeOfDay(hour: 23, minute: 45);

  static List<ScheduledEvent> _expandEvents(
      Interval day, List<ScheduledEvent> events) {
    List<ScheduledEvent> expanded = [];
    if (events.isEmpty || _startOfDay < events.first.at.start) {
      expanded.add(ScheduledEvent(
        name: 'Do something',
        at: Interval(
            day.at(_startOfDay),
            day.at(
                events.isEmpty ? _endOfDay : events.first.at.start.timeOfDay)),
      ));
    }
    // loop through events and add gaps
    for (var i = 0; i < events.length; i++) {
      expanded.add(events[i]);
      if (i + 1 < events.length && events[i].at.end < events[i + 1].at.start) {
        expanded.add(ScheduledEvent(
          name: 'Do something',
          at: Interval(day.at(events[i].at.end.timeOfDay),
              day.at(events[i + 1].at.start.timeOfDay)),
        ));
      }
    }
    if (events.isNotEmpty && _endOfDay > events.last.at.end) {
      expanded.add(ScheduledEvent(
        name: 'Do something',
        at: Interval(day.at(events.last.at.end.timeOfDay), day.at(_endOfDay)),
      ));
    }
    return expanded;
  }

  ScheduledDay(this.day, List<ScheduledEvent> events)
      : events = _expandEvents(day, events);

  final Interval day;
  final List<ScheduledEvent> events;

  @override
  List<Object> get props => [day, events];
}
