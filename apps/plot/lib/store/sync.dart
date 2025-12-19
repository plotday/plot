part of 'store.dart';

class SyncStates extends Table {
  TextColumn get entity => text()();

  // The most recent updated_at pulled (stored as microseconds since Unix epoch)
  IntColumn get pulledAt => integer().nullable()();

  // The timestamp of the first initial pull (stored as microseconds since epoch)
  // Used to filter out items in pullTo that were already synced via pull()
  IntColumn get firstPulledAt => integer().nullable()();

  // The last item pulled (stored as microseconds since Unix epoch)
  // For descending order: oldest item synced (pagination boundary moving backwards)
  // For ascending order: newest item synced (pagination boundary moving forwards)
  IntColumn get last => integer().nullable()();

  // True if we've reached the end of pagination (no more old/new items)
  // Replaces in-memory _noMore set with persistent storage
  BoolColumn get noMore => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {entity};
}
