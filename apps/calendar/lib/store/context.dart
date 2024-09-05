import 'package:drift/drift.dart';

import 'table.dart';
import 'types.dart';
import 'package:plot/util/order.dart';

class Contexts extends UuidStoreTable {
  TextColumn get name => text()();
  // TODO Factory to make with parent
  TextColumn get path => text()();
  RealColumn get order => real()
      .clientDefault(() => Order().toDouble())
      .map(const OrderConverter())();
  IntColumn get pomodoro =>
      integer().withDefault(const Constant(25)).map(const MinutesConverter())();
}

class ContextsBase extends BaseTable {
  ContextsBase() : super(table: 'context_x', name: "contexts");
}
