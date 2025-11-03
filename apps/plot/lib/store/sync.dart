part of 'store.dart';

class SyncStates extends Table {
  TextColumn get entity => text()();

  // The most recent updated_at pulled (stored as microseconds since Unix epoch)
  IntColumn get pulledAt => integer().nullable()();
  // The last item pulled (stored as microseconds since Unix epoch), or null if all have been pulled
  IntColumn get last => integer().nullable()();

  @override
  Set<Column> get primaryKey => {entity};
}
