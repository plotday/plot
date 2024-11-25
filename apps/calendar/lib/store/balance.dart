part of 'store.dart';

enum BalanceType {
  accepted,
  tentative,
  declined,
  session,
  todo,
  done,
}

typedef BalanceByType = Map<BalanceType, BalanceStats>;
typedef BalanceByActivityType = Map<ActivityId?, BalanceByType>;
typedef BalanceByDateActivityType = Map<Date, BalanceByActivityType>;

@DataClassName('BalanceRow')
class Balances extends StoreTable {
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();
  TextColumn get day => text().map(const DateConverter())();
  TextColumn get type => textEnum<BalanceType>()();

  IntColumn get count => integer().withDefault(const Constant(0))();

  @JsonKey('seconds')
  IntColumn get time =>
      integer().withDefault(const Constant(0)).map(const DurationConverter())();

  @override
  Set<Column> get primaryKey => {activityId, day, type};
}

class BalanceBase extends BaseTable {
  BalanceBase({super.filterName})
      : super(
          table: 'balance',
          order: 'day',
        );

  @override
  Insertable<BalanceRow> fromBase(Map<String, dynamic> json) =>
      BalanceRow.fromJson(json);
}

class WeekBalanceBase extends BalanceBase {
  WeekBalanceBase(this.week)
      : super(
          filterName: week.start.toString(),
        );

  final Week week;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    return query
        .gte('day', week.start.toString())
        .lt('day', week.end.toString());
  }
}

class Balance extends BalanceRow {
  static $BalancesTable get table => Store.get.balances;

  static Future<bool> pull() =>
      Store.get.pull(PullType.updates, table, BalanceBase());

  static Future<bool> pullRange(DateRange range) =>
      Store.get.pull(PullType.more, table, BalanceBase(),
          range: (range.start.toString(), range.end.toString()));

  static Future<bool> pullWeek(
    Week week,
  ) =>
      Store.get.pull(PullType.all, table, WeekBalanceBase(week));

  static Stream<BalanceByDateActivityType> watchDaily(DateRange range) {
    pullRange(range);

    final query = Store.get.select(table)
      ..where((t) => t.count.isBiggerThanValue(0))
      ..where((t) => t.day.isBiggerOrEqualValue(range.start.toString()))
      ..where((t) => t.day.isSmallerThanValue(range.end.toString()));
    final balanceStats = query.watch().map((List<BalanceRow> rows) {
      final BalanceByDateActivityType result = {};
      for (final row in rows) {
        final activityId = row.activityId;
        final day = row.day;
        final type = row.type;
        final balanceStat = BalanceStats(
          time: row.time,
          count: row.count,
        );
        result.putIfAbsent(day, () => {});
        result[day]!.putIfAbsent(activityId, () => {});
        result[day]![activityId]![type] = balanceStat;
      }
      return result;
    });

    final eventStats = Event.watch(Day.today()).map((events) => groupBy(
            events, (event) => event.activityId)
        .map((activityId, events) => MapEntry(
            activityId,
            groupBy(events, (event) => event.balanceType).map(
                (activityId, events) => MapEntry(activityId,
                    TimeBasedBalanceStats(events.map((event) => event.at).toList()))))));

    final noteStats = Note.watchActive().map((notes) =>
        groupBy(notes, (note) => note.activityId).map((activityId, notes) {
          return MapEntry(activityId, {
            BalanceType.todo: TimeBasedBalanceStats(notes
                .map((note) => DateTimeRange(note.doAt!, note.doAt!))
                .toList())
          });
        }));

    return Rx.combineLatest3(
        Date.current(),
        balanceStats,
        Rx.combineLatest3(
          Activity.watchAll(),
          eventStats,
          noteStats,
          (activities, events, notes) {
            return combineNestedMaps(
              _aggregateChildBalances(events, activities, null),
              _aggregateChildBalances(notes, activities, null),
            );
          },
        ), (
      Date today,
      BalanceByDateActivityType balanceMap,
      BalanceByActivityType todayMap,
    ) {
      balanceMap[today] = todayMap;
      return balanceMap;
    });
  }

  static Stream<BalanceByActivityType> watch(DateRange range) {
    return Rx.combineLatest2(Date.current(), watchDaily(range),
        (today, dailyBalanceMap) {
      final combinedBalanceByActivityType = <ActivityId?, BalanceByType>{};
      for (var date in dailyBalanceMap.keys) {
        final balanceByActivityType = dailyBalanceMap[date]!;
        for (var activityEntry in balanceByActivityType.entries) {
          final activityId = activityEntry.key;
          final balanceByType = activityEntry.value;
          final combinedBalanceByType = combinedBalanceByActivityType
              .putIfAbsent(activityId, () => <BalanceType, BalanceStats>{});

          for (var balanceTypeEntry in balanceByType.entries) {
            final balanceType = balanceTypeEntry.key;
            // Today includes all currently active todos, so we ignore todos
            // from previous days
            if (balanceType == BalanceType.todo &&
                range.includes(today) &&
                date < today) {
              continue;
            }
            final balanceStat = balanceTypeEntry.value;
            combinedBalanceByType.update(
              balanceType,
              (existingStat) => existingStat + balanceStat,
              ifAbsent: () => balanceStat,
            );
          }
        }
      }

      return combinedBalanceByActivityType;
    });
  }

  Balance.fromStore(BalanceRow row)
      : super(
          modifiedAt: row.modifiedAt,
          day: row.day,
          activityId: row.activityId,
          type: row.type,
          count: row.count,
          time: row.time,
        );
}

class BalanceStats {
  const BalanceStats({required this.count, required this.time});

  final int count;
  final Duration time;

  // The current value of count and time are valid until the given DateTime.
  // If null, they are valid indefinitely.
  DateTime? validateUntil() => null;

  BalanceStats operator +(BalanceStats other) {
    if (other is TimeBasedBalanceStats) {
      return other + this;
    } else {
      return BalanceStats(
        count: count + other.count,
        time: time + other.time,
      );
    }
  }

  @override
  String toString() => 'BalanceStats{count: $count, time: $time}';
}

class TimeBasedBalanceStats extends BalanceStats {
  TimeBasedBalanceStats(
    this.occurrences, {
    super.count = 0,
    super.time = Duration.zero,
  });

  final List<DateTimeRange> occurrences;
  List<DateTimeRange> get currentOccurrences => occurrences
      .where((occurrence) => occurrence.start.isSameOrBefore(DateTime.now()))
      .toList();

  @override
  int get count => super.count + currentOccurrences.length;
  @override
  Duration get time => currentOccurrences.fold<Duration>(
        super.time,
        (total, occurrence) => total + occurrence.duration,
      );

  @override
  DateTime? validateUntil() => occurrences
      .map((occurrence) => occurrence.start)
      .where((start) => start.isAfter(DateTime.now()))
      .reduce((a, b) => a.isBefore(b) ? a : b);

  int get _count => super.count;
  Duration get _time => super.time;

  @override
  TimeBasedBalanceStats operator +(BalanceStats other) {
    if (other is TimeBasedBalanceStats) {
      return TimeBasedBalanceStats(
        occurrences + other.occurrences,
        count: super.count + other._count,
        time: super.time + other._time,
      );
    } else {
      return TimeBasedBalanceStats(
        occurrences,
        count: super.count + other.count,
        time: super.time + other.time,
      );
    }
  }
}

BalanceByActivityType _aggregateChildBalances(
  BalanceByActivityType balanceByActivity,
  List<Activity> children,
  ActivityId? activityId,
) {
  BalanceByActivityType newBalances = {};
  if (balanceByActivity[activityId]?.isNotEmpty == true) {
    newBalances[activityId] = Map.of(balanceByActivity[activityId]!);
  }
  for (var child in children) {
    final childBalances =
        _aggregateChildBalances(balanceByActivity, child.children, child.id);
    if (childBalances.isEmpty) continue;
    newBalances.addAll(childBalances);
    if (newBalances[activityId] == null) {
      newBalances[activityId] = childBalances[child.id]!;
      continue;
    }
    final BalanceByType newBalance = {};
    for (var balanceType in BalanceType.values) {
      final balanceStat1 = newBalances[activityId]![balanceType];
      final balanceStat2 = childBalances[child.id]![balanceType];
      if (balanceStat1 == null && balanceStat2 == null) continue;
      if (balanceStat1 == null || balanceStat2 == null) {
        newBalance[balanceType] = (balanceStat1 ?? balanceStat2)!;
        continue;
      }
      newBalance[balanceType] = balanceStat1 + balanceStat2;
    }
    newBalances[activityId] = newBalance;
  }
  return newBalances;
}
