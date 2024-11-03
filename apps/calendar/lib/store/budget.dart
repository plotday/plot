part of 'store.dart';

@DataClassName('BudgetRow')
class Budgets extends IdStoreTable {
  BlobColumn get activityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Activities, #id)();
}

class BudgetsBase extends BaseTable {
  BudgetsBase() : super(table: 'budget');

  @override
  Insertable<BudgetRow> fromBase(Map<String, dynamic> json) {
    return BudgetRow.fromJson(json);
  }
}

class Budget extends BudgetRow {
  static TableInfo<Budgets, BudgetRow> get table => Store.get.budgets;

  static Future<void> push() => Store.get.push(table, BudgetsBase());
  static Future<bool> pull() => Store.get.pull(table, BudgetsBase());

  Budget.fromStore(BudgetRow row)
      : super(
          id: row.id,
          modifiedAt: row.modifiedAt,
          activityId: row.activityId,
        );

  Future<void> save() => Store.get.save(table, this);
}
