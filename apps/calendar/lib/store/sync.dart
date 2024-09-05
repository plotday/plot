import 'package:drift/drift.dart';

class SyncStates extends Table {
  TextColumn get entity => text()();

  // Local timestamp of the most recent row pushed
  DateTimeColumn get pushedAt => dateTime().nullable()();
  // Value of the order field of the last item pulled
  TextColumn get lastPulled => text().nullable()();
  BoolColumn get more => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {entity};
}
