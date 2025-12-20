part of 'store.dart';

/// Tracks sync state for each entity.
///
/// Entity Naming Convention:
/// - Regular sync: entity name (e.g., "activities", "priorities")
/// - Archived sync: entity name + "_archived" (e.g., "activities_archived", "priorities_archived")
///
/// Sync State Fields Usage:
///
/// Regular Sync (all entities):
/// - pulledAt: Timestamp of last update pull (based on updated_at)
/// - firstPulledAt: Timestamp of first initial pull
/// - last: Pagination boundary (based on created_at) - Activities only
/// - noMore: True when pagination is complete - Activities only
///
/// Archived Sync:
/// - Activities: Uses pullTo() with archived=true for pagination
///   - last: Pagination boundary for archived items
///   - noMore: True when archived pagination is complete
///   - pulledAt, firstPulledAt: Not used (remain null)
///
/// - Other entities (Priority, Note, Actor, Session): Use pullArchived() for one-time fetch
///   - pulledAt: Marks completion of archived items fetch
///   - firstPulledAt, last, noMore: Not used (remain null)
///
/// Sync Behavior:
/// - Initial pull: Fetches only non-archived items (archived_at IS NULL)
/// - More pull: Paginates only non-archived items (Activities only)
/// - Update pull: Fetches all updated items (including newly archived)
/// - Archived pull: Fetches archived items on-demand when archived=true or archived=null
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
