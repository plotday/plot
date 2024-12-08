part of 'store.dart';

class SyncStates extends Table {
  TextColumn get entity => text()();

  // Local timestamp of the most recent row pushed
  DateTimeColumn get pushedAt => dateTime().nullable()();
  // Value of the modified_at field of the latest item pulled
  DateTimeColumn get pulledAt => dateTime().nullable()();
  // Range synced
  TextColumn get from => text().nullable()();
  TextColumn get to => text().nullable()();
  BoolColumn get more => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {entity};
}
