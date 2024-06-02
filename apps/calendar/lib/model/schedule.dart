import 'package:equatable/equatable.dart';
import 'package:collection/collection.dart';

import 'package:plot/util/time.dart';
import 'package:plot/util/api.dart' as api;
import 'context.dart';
import 'model.dart';

enum EventResponse { accepted, declined, tentative }

class ScheduledEvent extends Model {
  static final Store<int, ScheduledEvent> store = Store();
  static const columns = 'id,series,name,at,invitees,context_id,response';

  static Future<ScheduledEvent> fetch(int id) async {
    final response = await base.from('event_x').select(columns).eq('id', id);
    return ScheduledEvent.fromJson(response.first);
  }

  static Future<ScheduledEvent> getOrFetch(int id) async {
    return store.has(id) ? store.get(id) : await fetch(id);
  }

  static List<ScheduledEvent> current() {
    final all = ScheduledDay.today();
    final now = DateTime.now();
    final current = all.events.where((ScheduledEvent event) {
      return event.at.includes(now);
    }).toList();
    return current;
  }

  static List<ScheduledEvent> next() {
    final all = ScheduledDay.today();
    final now = DateTime.now();
    var next = all.events.where((ScheduledEvent event) {
      return event.at.start.isAfter(now);
    }).toList();
    if (next.isNotEmpty) {
      next = all.events.where((ScheduledEvent event) {
        return event.at.start == next.first.at.start;
      }).toList();
    }
    return next;
  }

  static List<ScheduledEvent> previous() {
    final all = ScheduledDay.today();
    final now = DateTime.now();
    var previous = all.events.where((ScheduledEvent event) {
      return event.at.end.isBefore(now);
    }).toList();
    if (previous.isNotEmpty) {
      previous = all.events.where((ScheduledEvent event) {
        return event.at.end == previous.first.at.end;
      }).toList();
    }
    return previous;
  }

  ScheduledEvent({
    this.name,
    required this.at,
    super.id,
    Context? context,
    this.response = EventResponse.accepted,
    this.series,
    this.invitees = const [],
    ScheduledEvent? copiedFrom,
  })  : _contextId = context?.id,
        _copiedFrom = copiedFrom?._copiedFrom ?? copiedFrom;

  ScheduledEvent.fromJson(Map<String, dynamic> json)
      : series = json['series'] as String?,
        name = json['name'] as String?,
        at = DateTimeRange.fromString(json['at'] as String),
        invitees = (json['invitees'] as List).map((i) => i as String).toList(),
        _contextId = json['context_id'] as int?,
        _copiedFrom = null,
        response = EventResponse.values
            .byName((json['response'] as String?) ?? 'tentative'),
        super(id: json['id'] as int);

  @override
  Map<String, dynamic> toJson({bool patch = false}) => {
        'id': id,
        'user_id': base.auth.currentUser?.id,
        if (!patch || _copiedFrom?.name != name) 'name': name,
        if (!patch || _copiedFrom?.at != at) 'at': at.toString(),
        if (!patch || _copiedFrom?.response != response)
          'response': response.name,
      };

  ScheduledEvent copyWith({
    String? name,
    DateTimeRange? at,
    Context? context,
    EventResponse? response,
  }) {
    return ScheduledEvent(
      copiedFrom: this,
      id: id,
      series: series,
      name: name ?? this.name,
      at: at ?? this.at,
      invitees: invitees,
      context: context ?? this.context,
      response: response ?? this.response,
    );
  }

  final String? series;
  final String? name;
  final DateTimeRange at;
  final List<String> invitees;
  final EventResponse response;
  final int? _contextId;
  final ScheduledEvent? _copiedFrom;

  Context? get context =>
      _contextId == null ? null : Context.store.get(_contextId);

  @override
  List<Object> get props => [id ?? 0, name ?? '', at, _contextId ?? 0];

  @override
  Future<ScheduledEvent> save() async {
    final date = at.start.toDate();
    ScheduledDay.store.put(date, ScheduledDay.store.get(date).copyWith(this));
    Map<String, dynamic>? result;
    if (id == null) {
      result = await api.post(
        "/event",
        body: {
          'event': toJson(),
        },
      );
    } else {
      // TODO Only patch if there are changes
      store.put(id!, this);
      result = await api.patch(
        "/event/$id",
        body: {
          'event': toJson(patch: true),
        },
      );
    }
    store.put(result['id'] as int, this);

    if (context != null &&
        series != null &&
        (_copiedFrom?.series == null || _copiedFrom?.context != context)) {
      await base
          .from('series')
          .update(
            {
              'context_id': context!.id,
            },
          )
          .eq('user_id', base.auth.currentUser!.id)
          .eq('series', series!);
    }

    return ScheduledEvent(
      id: result['id'] as int,
      series: series,
      name: name,
      at: at,
      invitees: invitees,
      context: context,
      response: response,
    );
  }
}

class ScheduledDay extends Equatable {
  static final Store<Date, ScheduledDay> store = Store();

  static ScheduledDay get(Date date) {
    return list(date, date.next()).first;
  }

  // Returns the furthest date fetched
  static Future<Date> fetch(
    Date start, {
    TimeDirection direction = TimeDirection.ascending,
  }) async {
    if (_isExhausted(start)) {
      return start.addDays(30, direction: direction);
    }
    if (store.has(start)) {
      while (store.has(start)) {
        start = start.next(direction: direction);
      }
      return start;
    }
    var fetching = _fetchState[direction]!.fetching;
    if (fetching == null) {
      fetching = _fetch(start, direction);
      _fetchState[direction]!.fetching = fetching;
    }
    final next = await fetching;
    _fetchState[direction]!.fetching = null;
    assert(next != start, "Fetch returned the same date: $start");
    return next;
  }

  static List<ScheduledDay> list(Date start, Date end) {
    final direction =
        start < end ? TimeDirection.ascending : TimeDirection.descending;
    List<ScheduledDay> days = [];
    while (start != end) {
      days.add(
          store.has(start) ? store.get(start) : ScheduledDay(start, const []));
      start = start.next(direction: direction);
    }
    return days;
  }

  static ScheduledDay today() {
    if (store.has(Date.today())) {
      return store.get(Date.today());
    } else {
      get(Date.today());
      return ScheduledDay(Date.today(), const []);
    }
  }

  static Future<ScheduledDay> getOrFetchToday() async {
    await fetch(Date.today());
    return today();
  }

  ScheduledDay(this.date, List<ScheduledEvent> events)
      : events = _addGaps(
            date,
            events
                .where((e) => e.at.duration < const Duration(hours: 22))
                .toList()),
        allDayEvents = events
            .where((e) => e.at.duration >= const Duration(hours: 22))
            .toList();

  final Date date;
  final List<ScheduledEvent> events;
  final List<ScheduledEvent> allDayEvents;

  ScheduledDay copyWith(ScheduledEvent event) {
    final list = events.where((e) => e.id != event.id).toList();
    list.insert(list.indexWhere((i) => i.at < event.at), event);
    return ScheduledDay(date, list);
  }

  @override
  List<Object> get props => [date, events];

  /* Private */

  static Future<Date> _fetch(
    final Date start,
    TimeDirection direction,
  ) async {
    var leftovers = _fetchState[direction]!.leftovers[start];
    DateTime fetchStart;
    if (leftovers?.isNotEmpty == true) {
      fetchStart = direction == TimeDirection.ascending
          ? leftovers!.last.at.start
          : leftovers!.first.at.start;
    } else {
      fetchStart = start.toDateTime();
    }
    final response = await base
        .from('event_x')
        .select(ScheduledEvent.columns)
        .eq('user_id', base.auth.currentUser!.id)
        .overlaps(
            'at',
            direction == TimeDirection.ascending
                ? "[${fetchStart.toDb()},)"
                : "(,${(fetchStart + const Duration(days: 1)).toDb()})")
        .order('at', ascending: direction == TimeDirection.ascending)
        .limit(_pageSize);
    var items = response.expand<ScheduledEvent>((event) {
      try {
        return [ScheduledEvent.fromJson(event)];
      } catch (e) {
        print("Error parsing event: $e");
        print("Event: $event");
        return [];
      }
    }).toList();
    for (final event in items) {
      ScheduledEvent.store.put(event.id!, event);
    }

    // Merge leftovers, skipping duplicates
    if (leftovers?.isNotEmpty == true) {
      if (items.isEmpty) {
        items = leftovers!;
      } else {
        final match =
            leftovers!.indexWhere((event) => event.id == items.first.id);
        if (match != -1) {
          items = leftovers.sublist(
                0,
                match,
              ) +
              items;
        } else {
          print("Could not find match: ${items.first}");
          print(leftovers);
        }
      }
    }
    if (items.isEmpty) {
      _fetchState[direction]!.exhausted = start;
      return start + const Duration(days: 7);
    }
    _fetchState[TimeDirection.ascending]!.leftovers.remove(start);
    _fetchState[TimeDirection.descending]!.leftovers.remove(start);

    // Add complete days to the store
    final groupedItems = groupBy(items, (item) => item.at.start.toDate());
    final end = items.last.at.start.toDate();
    for (var date = start;
        items.isNotEmpty && date != end;
        date = date.next(direction: direction)) {
      store.put(
          date,
          ScheduledDay(
              date,
              (direction == TimeDirection.ascending
                      ? groupedItems[date]
                      : groupedItems[date]?.reversed.toList()) ??
                  []));
    }
    _fetchState[direction]!.leftovers[end] = groupedItems[end] ?? [];
    assert(end != start,
        "Fetched ${items.length} events over ${groupedItems.length} days");
    return end;
  }

  static bool _isExhausted(Date date) {
    final start = _fetchState[TimeDirection.descending]?.exhausted;
    final end = _fetchState[TimeDirection.ascending]?.exhausted;
    return (start != null && date <= start) || (end != null && date >= end);
  }

  static List<ScheduledEvent> _addGaps(Date date, List<ScheduledEvent> events) {
    List<ScheduledEvent> expanded = [];
    final start = date.toDateTime();
    final end = start.endOfDay;
    if (events.isEmpty ||
        events.first.at.start.difference(start).inMinutes > 0) {
      expanded.add(ScheduledEvent(
        at: DateTimeRange(
            start,
            events.isEmpty
                ? end
                : start.at(events.first.at.start.toTimeOfDay())),
      ));
    }
    for (var i = 0; i < events.length; i++) {
      expanded.add(events[i]);
      if (i + 1 == events.length || events[i].at.end < events[i + 1].at.start) {
        expanded.add(ScheduledEvent(
          at: DateTimeRange(
            events[i].at.end,
            i + 1 == events.length ? end : events[i + 1].at.start,
          ),
        ));
      }
    }
    return expanded;
  }

  static final _fetchState = {
    TimeDirection.ascending: _FetchState(),
    TimeDirection.descending: _FetchState(),
  };
  static const int _pageSize = 50;
}

class _FetchState {
  _FetchState() : leftovers = {};

  Future<Date>? fetching;
  Date? exhausted;
  Map<Date, List<ScheduledEvent>> leftovers;
}
