part of 'store.dart';

enum BalanceType {
  accepted,
  tentative,
  declined,
  session,
  do_now, // ignore: constant_identifier_names
  do_later, // ignore: constant_identifier_names
}

typedef BalanceByType = Map<BalanceType, BalanceStats>;
typedef BalanceByActivityType = Map<ActivityId?, BalanceByType>;
typedef BalanceByActivityDateType = Map<ActivityId?, Map<Date, BalanceByType>>;

@DataClassName('BalanceRow')
class Balances extends StoreTable {
  TextColumn get day => text().map(const DateConverter())();
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();
  TextColumn get type => textEnum<BalanceType>()();

  IntColumn get count => integer().withDefault(const Constant(0))();

  @JsonKey('seconds')
  IntColumn get time =>
      integer().withDefault(const Constant(0)).map(const DurationConverter())();
}

class BalanceBase extends BaseTable {
  BalanceBase({super.filterName})
      : super(
          table: 'balance',
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

  static Future<bool> pullWeek(
    Week week,
  ) =>
      Store.get.pull(PullType.all, table, WeekBalanceBase(week));

  static Stream<BalanceByActivityDateType> watchDaily(
    DateRange range, {
    Path? path,
    int? depth = 1, // number of child levels to include
  }) {
    final query = Store.get.select(table).join([
      leftOuterJoin(
          Activity.table, Activity.table.id.equalsExp(table.activityId)),
    ])
      ..where(table.day.isBiggerOrEqualValue(range.start.toString()))
      ..where(table.day.isSmallerThanValue(range.end.toString()));

    if (path != null) {
      query.where(Activity.table.path.like("$path%"));
    }
    if (depth != null) {
      query.where(Activity.pathDepth(path, depth));
    }

    final order =
        range.start <= range.end ? OrderingMode.asc : OrderingMode.desc;
    query.orderBy([
      OrderingTerm(expression: table.day, mode: order),
    ]);

    return query.watch().map(
          (rows) => {
            for (final row in rows)
              row.readTable(table).activityId: {
                for (final row in rows)
                  row.readTable(table).day: {
                    for (final row in rows)
                      row.readTable(table).type: BalanceStats(
                        time: row.readTable(table).time,
                        count: row.readTable(table).count,
                      ),
                  },
              },
          },
        );
  }

  static Stream<BalanceByActivityType> watch(
    DateRange range, {
    Path? path,
    int? depth = 1, // number of child levels to include
  }) {
    return watchDaily(range, path: path, depth: depth).map((dailyBalanceMap) {
      final balanceMap = <ActivityId?, Map<BalanceType, BalanceStats>>{};

      for (final activityId in dailyBalanceMap.keys) {
        final dailyMap = dailyBalanceMap[activityId]!;

        final typeStatsMap = <BalanceType, BalanceStats>{};

        for (final date in dailyMap.keys) {
          final balanceTypeMap = dailyMap[date]!;

          for (final balanceType in balanceTypeMap.keys) {
            final balance = balanceTypeMap[balanceType]!;

            final currentStats = typeStatsMap[balanceType];
            final updatedCount = (currentStats?.count ?? 0) + balance.count;
            final updatedTime =
                (currentStats?.time ?? const Duration()) + balance.time;

            typeStatsMap[balanceType] =
                BalanceStats(count: updatedCount, time: updatedTime);
          }
        }

        balanceMap[activityId] = typeStatsMap;
      }

      return balanceMap;
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
}
