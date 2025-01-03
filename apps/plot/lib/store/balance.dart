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

    return Date.current().switchMap((today) {
      final query = Store.get.select(table)
        ..where((t) => t.count.isBiggerThanValue(0))
        ..where((t) => t.day.isBiggerOrEqualValue(range.start.toString()))
        ..where((t) => t.day.isNotValue(today.toString()))
        ..where((t) => t.day.isSmallerThanValue(range.end.toString()));
      final balanceStats = query.watch().map((List<BalanceRow> rows) {
        final BalanceByDateActivityType result = {};
        for (final row in rows) {
          final activityId = row.activityId;
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
          result[day]!.putIfAbsent(activityId, () => {});
          result[day]![activityId]![type] = balanceStat;
        }
        return result;
      });

      final eventStats = !range.includes(today)
          ? Stream.value(BalanceByActivityType.from({}))
          : ScheduledDay.watchToday().map(((day) {
              final now = DateTime.now();
              return groupBy(
                  day.events, (Event e) => (e.activityId, e.response)).map(
                (key, events) {
                  final activityId = key.$1;
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
                  return MapEntry(activityId, {
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

      final noteStats = !range.includes(today)
          ? Stream.value(BalanceByActivityType.from({}))
          : Note.watchActive().transform(ExpiringStreamTransformer((notes) {
              final now = DateTime.now();
              return ExpiringResult(
                value: groupBy(notes, (note) => note.activityId)
                    .map((activityId, notes) {
                  final pastCount = notes
                      .where((note) => note.doAt!.isSameOrBefore(now))
                      .length;
                  return MapEntry(activityId, {
                    BalanceType.todo: BalanceStats(
                      pastCount: pastCount,
                      futureCount: notes.length - pastCount,
                    )
                  });
                }),
                expiry: notes
                    .map((note) => note.doAt!)
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
          ? Stream.value(BalanceByActivityType.from({}))
          : Session.watch(range: today.toDateRange(), expiring: true)
              .map((sessions) {
              final now = DateTime.now();
              return groupBy(sessions, (session) => session.activityId)
                  .map((activityId, groupedSessions) => MapEntry(activityId, {
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
          Rx.combineLatest4(
            Activity.watchAll(),
            eventStats,
            noteStats,
            sessionStats,
            (activities, events, notes, sessions) {
              return combineNestedMaps([
                _aggregateChildBalances(events, activities, null),
                _aggregateChildBalances(notes, activities, null),
                _aggregateChildBalances(sessions, activities, null),
              ]);
            },
          ), (
        BalanceByDateActivityType balanceMap,
        BalanceByActivityType todayMap,
      ) {
        balanceMap[today] = todayMap;
        return balanceMap;
      });
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
          updatedAt: row.updatedAt,
          day: row.day,
          activityId: row.activityId,
          type: row.type,
          count: row.count,
          time: row.time,
        );
}

class BalanceStats {
  const BalanceStats(
      {this.pastCount = 0,
      this.pastTime = Duration.zero,
      this.futureCount = 0,
      this.futureTime = Duration.zero});

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
