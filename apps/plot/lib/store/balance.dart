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
typedef BalanceByPriorityType = Map<PriorityId?, BalanceByType>;
typedef BalanceByDatePriorityType = Map<Date, BalanceByPriorityType>;

@DataClassName('BalanceRow')
class Balances extends StoreTable {
  BlobColumn get priorityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Priorities, #id)();
  TextColumn get day => text().map(const DateConverter())();
  TextColumn get type => textEnum<BalanceType>()();

  IntColumn get count => integer().withDefault(const Constant(0))();

  @JsonKey('seconds')
  IntColumn get time =>
      integer().withDefault(const Constant(0)).map(const DurationConverter())();

  @override
  Set<Column> get primaryKey => {priorityId, day, type};
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

  static Stream<BalanceByDatePriorityType> watchDaily(DateRange range) {
    pullRange(range);

    return Rx.switchLatest(Rx.combineLatest2(
        Date.current(), Priority.watchAll(), (today, priorities) {
      final query = Store.get.select(table)
        ..where((t) => t.count.isBiggerThanValue(0))
        ..where((t) => t.day.isBiggerOrEqualValue(range.start.toString()))
        ..where((t) => t.day.isNotValue(today.toString()))
        ..where((t) => t.day.isSmallerThanValue(range.end.toString()));
      final balanceStats = query.watch().map((List<BalanceRow> rows) {
        final BalanceByDatePriorityType result = {};
        for (final row in rows) {
          final priorityId = row.priorityId;
          final day = row.day;
          final type = row.type;
          final balanceStat = row.day < today
              ? BalanceStats(
                  pastTime: row.time,
                  pastCount: row.count,
                )
              : BalanceStats(
                  futureTime: row.time,
                  futureCount: row.count,
                );
          result.putIfAbsent(day, () => {});
          result[day]!.putIfAbsent(priorityId, () => {});
          result[day]![priorityId]![type] = balanceStat;
        }

        // For each day, aggregate the stats up the priority hierarchy
        final aggregatedBalanceMap =
            Map<Date, BalanceByPriorityType>.from(result);
        for (final date in aggregatedBalanceMap.keys) {
          final dayStats = aggregatedBalanceMap[date]!;
          aggregatedBalanceMap[date] =
              _aggregateChildBalances(dayStats, priorities, null);
        }
        return aggregatedBalanceMap;
      });

      final eventStats = !range.includes(today)
          ? Stream.value(BalanceByPriorityType.from({}))
          : ScheduledDay.watchToday().map(((day) {
              final now = DateTime.now();
              return groupBy(
                  day.events, (Event e) => (e.priorityId, e.response)).map(
                (key, events) {
                  final priorityId = key.$1;
                  final response = key.$2;
                  final type = switch (response) {
                    EventResponse.accepted => BalanceType.accepted,
                    EventResponse.tentative => BalanceType.tentative,
                    EventResponse.declined => BalanceType.declined,
                  };
                  final pastEvents =
                      events.where((event) => event.at.end.isBefore(now));
                  final currentEvents =
                      events.where((event) => event.at.includes(now));
                  final futureEvents =
                      events.where((event) => event.at.start.isAfter(now));
                  return MapEntry(priorityId, {
                    type: BalanceStats(
                      pastCount: pastEvents.length,
                      pastTime: pastEvents
                              .toList()
                              .map((event) => event.at.duration)
                              .fold(Duration.zero, (a, b) => a + b) +
                          currentEvents
                              .toList()
                              .map((event) => now.difference(event.at.end))
                              .fold(Duration.zero, (a, b) => a + b),
                      futureCount: currentEvents.length + futureEvents.length,
                      futureTime: futureEvents
                              .toList()
                              .map((event) => event.at.duration)
                              .fold(Duration.zero, (a, b) => a + b) +
                          currentEvents
                              .toList()
                              .map((event) => event.at.end.difference(now))
                              .fold(Duration.zero, (a, b) => a + b),
                    )
                  });
                },
              );
            }));

      final activityStats = !range.includes(today)
          ? Stream.value(BalanceByPriorityType.from({}))
          : Activity.watchActive()
              .transform(ExpiringStreamTransformer((activities) {
              final now = DateTime.now();
              return ExpiringResult(
                value: groupBy(activities, (activity) => activity.priorityId)
                    .map((priorityId, activities) {
                  final pastCount = activities
                      .where((activity) => activity.doAt!.isSameOrBefore(now))
                      .length;
                  return MapEntry(priorityId, {
                    BalanceType.todo: BalanceStats(
                      pastCount: pastCount,
                      futureCount: activities.length - pastCount,
                    )
                  });
                }),
                expiry: activities
                    .map((activity) => activity.doAt!)
                    .where((start) => start.isAfter(now))
                    .fold(
                        null,
                        (a, b) => a == null
                            ? b
                            : a.isBefore(b)
                                ? a
                                : b),
              );
            }));

      final sessionStats = !range.includes(today)
          ? Stream.value(BalanceByPriorityType.from({}))
          : Session.watch(range: today.toDateRange(), expiring: true)
              .map((sessions) {
              final now = DateTime.now();
              return groupBy(sessions, (session) => session.priorityId)
                  .map((priorityId, groupedSessions) => MapEntry(priorityId, {
                        BalanceType.session: BalanceStats(
                          pastCount: groupedSessions.length,
                          pastTime: groupedSessions
                              .map((session) => session.end
                                  .max(now)
                                  .difference(session.start))
                              .fold(Duration.zero, (a, b) => a + b),
                        )
                      }));
            });

      return Rx.combineLatest2(
          balanceStats,
          Rx.combineLatest3(
            eventStats,
            activityStats,
            sessionStats,
            (events, notes, sessions) {
              return combineNestedMaps([
                _aggregateChildBalances(events, priorities, null),
                _aggregateChildBalances(notes, priorities, null),
                _aggregateChildBalances(sessions, priorities, null),
              ]);
            },
          ), (
        BalanceByDatePriorityType balanceMap,
        BalanceByPriorityType todayMap,
      ) {
        balanceMap[today] = todayMap;
        return balanceMap;
      });
    }));
  }

  static Stream<BalanceByPriorityType> watch(DateRange range) {
    return Rx.combineLatest2(Date.current(), watchDaily(range),
        (today, dailyBalanceMap) {
      final combinedBalanceByPriorityType = <PriorityId?, BalanceByType>{};
      for (var date in dailyBalanceMap.keys) {
        final balanceByPriorityType = dailyBalanceMap[date]!;
        for (var activityEntry in balanceByPriorityType.entries) {
          final priorityId = activityEntry.key;
          final balanceByType = activityEntry.value;
          final combinedBalanceByType = combinedBalanceByPriorityType
              .putIfAbsent(priorityId, () => <BalanceType, BalanceStats>{});

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

      return combinedBalanceByPriorityType;
    });
  }

  Balance.fromStore(BalanceRow row)
      : super(
          updatedAt: row.updatedAt,
          day: row.day,
          priorityId: row.priorityId,
          type: row.type,
          count: row.count,
          time: row.time,
        );
}

class BalanceStats {
  const BalanceStats({
    this.pastCount = 0,
    this.pastTime = Duration.zero,
    this.futureCount = 0,
    this.futureTime = Duration.zero,
  });

  BalanceStats.aggregate(List<BalanceStats> stats)
      : this(
          pastCount: stats.fold<int>(0, (a, b) => a + b.pastCount),
          pastTime:
              stats.fold<Duration>(Duration.zero, (a, b) => a + b.pastTime),
          futureCount: stats.fold<int>(0, (a, b) => a + b.futureCount),
          futureTime:
              stats.fold<Duration>(Duration.zero, (a, b) => a + b.futureTime),
        );

  final int pastCount;
  final Duration pastTime;
  final int futureCount;
  final Duration futureTime;
  int get count => pastCount + futureCount;
  Duration get time => pastTime + futureTime;

  BalanceStats operator +(BalanceStats other) {
    return BalanceStats(
      pastCount: pastCount + other.pastCount,
      pastTime: pastTime + other.pastTime,
      futureCount: futureCount + other.futureCount,
      futureTime: futureTime + other.futureTime,
    );
  }

  @override
  String toString() =>
      'BalanceStats(count: $pastCount/$count, time: $pastTime/$time)';
}

BalanceByPriorityType _aggregateChildBalances(
  BalanceByPriorityType balanceByPriority,
  List<Priority> children,
  PriorityId? priorityId,
) {
  BalanceByPriorityType newBalances = {};
  if (balanceByPriority[priorityId]?.isNotEmpty == true) {
    newBalances[priorityId] = Map.of(balanceByPriority[priorityId]!);
  }
  for (var child in children) {
    final childBalances =
        _aggregateChildBalances(balanceByPriority, child.children, child.id);
    if (childBalances.isEmpty) continue;
    newBalances.addAll(childBalances);
    if (newBalances[priorityId] == null) {
      newBalances[priorityId] = childBalances[child.id]!;
      continue;
    }
    final BalanceByType newBalance = {};
    for (var balanceType in BalanceType.values) {
      final balanceStat1 = newBalances[priorityId]![balanceType];
      final balanceStat2 = childBalances[child.id]![balanceType];
      if (balanceStat1 == null && balanceStat2 == null) continue;
      if (balanceStat1 == null || balanceStat2 == null) {
        newBalance[balanceType] = (balanceStat1 ?? balanceStat2)!;
        continue;
      }
      newBalance[balanceType] = balanceStat1 + balanceStat2;
    }
    newBalances[priorityId] = newBalance;
  }
  return newBalances;
}
