import 'package:drift/drift.dart';

class PushStates extends Table {
  TextColumn get entity => text()();
  // Local timestamp of the most recent row pushed
  DateTimeColumn get at => dateTime()();

  @override
  Set<Column> get primaryKey => {entity};
}

class PullStates extends Table {
  TextColumn get entity => text()();
  // Server timestamp of the most recent row pulled
  DateTimeColumn get at => dateTime()();
  TextColumn get last => text().nullable()();
  BoolColumn get done => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {entity};
}
