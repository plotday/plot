part of 'store.dart';

enum BalanceType {
  past,
  scheduled,
  tentative,
}

@DataClassName('BalanceRow')
class Balances extends StoreTable {
  TextColumn get day => text()();
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();
  IntColumn get type => intEnum<BalanceType>()();

  IntColumn get count => integer().withDefault(const Constant(0))();

  @JsonKey('seconds')
  IntColumn get time =>
      integer().withDefault(const Constant(0)).map(const DurationConverter())();
}

class BalancesBase extends BaseTable {
  BalancesBase() : super(table: 'balance');

  @override
  Insertable<BalanceRow> fromBase(Map<String, dynamic> json) =>
      BalanceRow.fromJson(json);
}

class Balance extends BalanceRow {
  static $BalancesTable get table => Store.get.balances;

  static Future<bool> pull(
    Date from,
    Date to, {
    Path? path,
    int? depth = 1, // number of child levels to include
  }) =>
      Store.get.pull(table, BalancesBase());

  static Stream<Map<Uuid?, Balance>> watch(
    Date from,
    Date to, {
    Path? path,
    int? depth = 1, // number of child levels to include
  }) {
    final query = Store.get.select(table).join([
      leftOuterJoin(
          Activity.table, Activity.table.id.equalsExp(table.activityId)),
    ])
      ..where(table.day.isBiggerOrEqualValue(from.toString()))
      ..where(table.day.isSmallerThanValue(to.toString()));

    if (path != null) {
      query.where(Activity.table.path.like("$path%"));
    }
    if (depth != null) {
      query.where(Activity.pathDepth(path, depth));
    }

    final order = from <= to ? OrderingMode.asc : OrderingMode.desc;
    query.orderBy([
      OrderingTerm(expression: table.day, mode: order),
    ]);

    return query.watch().map((rows) => {
          for (final row in rows)
            row.readTable(table).activityId:
                Balance.fromStore(row.readTable(table))
        });
  }

  Balance.fromStore(BalanceRow row, {this.context})
      : super(
          modifiedAt: row.modifiedAt,
          day: row.day,
          activityId: row.activityId,
          type: row.type,
          count: row.count,
          time: row.time,
        );

  final Activity? context;
}
