part of 'store.dart';

enum BalanceType {
  past,
  scheduled,
  tentative,
}

@DataClassName('BalanceRow')
class Balances extends StoreTable {
  TextColumn get day => text()();
  BlobColumn get contextId =>
      blob().nullable().map(const UuidConverter()).references(Contexts, #id)();
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
      leftOuterJoin(Context.table, Context.table.id.equalsExp(table.contextId)),
    ])
      ..where(table.day.isBiggerOrEqualValue(from.toString()))
      ..where(table.day.isSmallerThanValue(to.toString()));

    if (path != null) {
      query.where(Context.table.path.like("$path%"));
    }
    if (depth != null) {
      query.where(Context.pathDepth(path, depth));
    }

    final order = from <= to ? OrderingMode.asc : OrderingMode.desc;
    query.orderBy([
      OrderingTerm(expression: table.day, mode: order),
    ]);

    return query.watch().map((rows) => {
          for (final row in rows)
            row.readTable(table).contextId:
                Balance.fromStore(row.readTable(table))
        });
  }

  Balance.fromStore(BalanceRow row, {this.context})
      : super(
          modifiedAt: row.modifiedAt,
          day: row.day,
          contextId: row.contextId,
          type: row.type,
          count: row.count,
          time: row.time,
        );

  final Context? context;
}
