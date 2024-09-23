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

  IntColumn get balances => integer().withDefault(const Constant(0))();
  IntColumn get seconds => integer().withDefault(const Constant(0))();
}

class BalancesBase extends BaseTable {
  BalancesBase() : super(table: 'balance');

  @override
  Insertable<BalanceRow> fromBase(Map<String, dynamic> json) =>
      BalanceRow.fromJson(json);
}

class Balance extends BalanceRow {
  static TableInfo<Balances, BalanceRow> get table => Store.get.balances;

  static Future<bool> pull() => Store.get.pull(table, BalancesBase());

  static Stream<List<Balance>> watch(Date from, Date to) {
    final order = from <= to ? OrderingMode.asc : OrderingMode.desc;
    return (Store.get.select(table)
          ..where((t) => t.day.isBiggerOrEqualValue(from.toString()))
          ..where((t) => t.day.isSmallerThanValue(to.toString()))
          ..orderBy([
            (t) => OrderingTerm(expression: t.day, mode: order),
          ]))
        .watch()
        .map((rows) => rows.map((row) => Balance.fromStore(row)).toList());
  }

  static Stream<List<Balance>> watchWithContext(Date from, Date to) =>
      Rx.combineLatest2(
          Balance.watch(from, to),
          Context.watch(),
          (List<Balance> balances, Map<Uuid, Context> contexts) => balances
              .map((balance) => Balance.fromStore(balance,
                  context: balance.contextId == null
                      ? null
                      : contexts[balance.contextId]))
              .toList());

  Balance.fromStore(BalanceRow row, {this.context})
      : super(
          modifiedAt: row.modifiedAt,
          day: row.day,
          contextId: row.contextId,
          type: row.type,
          balances: row.balances,
          seconds: row.seconds,
        );

  final Context? context;
}
