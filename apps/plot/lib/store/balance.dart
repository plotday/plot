part of 'store.dart';

enum BalanceType { accepted, tentative, declined, session, todo, done }

typedef BalanceByType = Map<BalanceType, BalanceStats>;
typedef BalanceByPriorityType = Map<PriorityId?, BalanceByType>;
typedef BalanceByDatePriorityType = Map<Date, BalanceByPriorityType>;

@DataClassName('BalanceRow')
class Balances extends Table with SyncableTable {
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
  BalanceBase({super.filterName}) : super(table: 'balance', order: 'day');

  @override
  Insertable<BalanceRow> fromBase(Map<String, dynamic> json) =>
      BalanceRow.fromJson(json);
}

class WeekBalanceBase extends BalanceBase {
  WeekBalanceBase(this.week) : super(filterName: week.start.toString());

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

  static Future<bool> pullRange(DateRange range) => Store.get.pull(
    PullType.more,
    table,
    BalanceBase(),
    range: (range.start.toString(), range.end.toString()),
  );

  static Future<bool> pullWeek(Week week) =>
      Store.get.pull(PullType.all, table, WeekBalanceBase(week));

  /// Watch the daily balances across a date range.
  static Stream<BalanceByDatePriorityType> watchDaily(DateRange range) {
    pullRange(range);

    // This could be more efficient if we only reevluated the current day on expiry, rather than the whole range.
    return Date.current().switchMap((today) {
      return streamWithExpiry(() {
        return (Store.get.select(Store.get.aggregatedBalances)
              ..where((t) => t.day.isBiggerOrEqualValue(range.start.toString()))
              ..where((t) => t.day.isSmallerThanValue(range.end.toString())))
            .watch()
            .map((rows) {
              final BalanceByDatePriorityType result = {};
              var nextAt = today.toEnd();
              for (final row in rows) {
                final balanceStat = BalanceStats(
                  pastTime: Duration(seconds: row.pastTime ?? 0),
                  futureTime: Duration(seconds: row.futureTime ?? 0),
                  pastCount: row.pastCount ?? 0,
                  futureCount: row.futureCount ?? 0,
                );
                result.putIfAbsent(row.day, () => {});
                result[row.day]!.putIfAbsent(row.priorityId, () => {});
                result[row.day]![row.priorityId]![row.type ??
                        BalanceType.tentative] =
                    balanceStat;
                if (row.nextAt != null && row.nextAt!.isBefore(nextAt)) {
                  nextAt = row.nextAt!;
                }
              }
              return ExpiringResult(value: result, expiry: nextAt);
            });
      });
    });
  }

  /// Aggregates all balances for the given date range.
  static Stream<BalanceByPriorityType> watch(DateRange range) {
    return Rx.combineLatest2(Date.current(), watchDaily(range), (
      today,
      dailyBalanceMap,
    ) {
      final combinedBalanceByPriorityType = <PriorityId?, BalanceByType>{};
      for (var date in dailyBalanceMap.keys) {
        final balanceByPriorityType = dailyBalanceMap[date]!;
        for (var priorityEntry in balanceByPriorityType.entries) {
          final priorityId = priorityEntry.key;
          final balanceByType = priorityEntry.value;
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
        pastTime: stats.fold<Duration>(Duration.zero, (a, b) => a + b.pastTime),
        futureCount: stats.fold<int>(0, (a, b) => a + b.futureCount),
        futureTime: stats.fold<Duration>(
          Duration.zero,
          (a, b) => a + b.futureTime,
        ),
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
