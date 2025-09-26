part of 'store.dart';

class SyncStates extends Table {
  TextColumn get entity => text()();

  // The most recent updated_at pulled
  DateTimeColumn get pulledAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  // The last item pulled, or null if all have been pulled
  TextColumn get last => text().nullable()();

  @override
  Set<Column> get primaryKey => {entity};
}
