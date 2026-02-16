part of 'store.dart';

@DataClassName('PriorityActorRow')
class PriorityActors extends Table with SyncableTable, CreatedTable, DeletableTable {
  BlobColumn get userId => blob().map(const UuidConverter())();
  TextColumn get priorityPath => text().map(const PathConverter())();
  BlobColumn get actorId => blob().map(const ActorIdConverter())();

  @override
  Set<Column> get primaryKey => {userId, priorityPath, actorId};
}

class PriorityActorsBase extends BaseTable {
  PriorityActorsBase()
    : super(
        table: 'user_priority_actor',
        syncEndpoint: 'priority-actors',
        name: "priority_actors",
        order: 'updated_at',
        ascending: false,
        cursorColumn: 'actor_id',
      );

  @override
  Insertable<PriorityActorRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    // userId is implicit via RLS in the view, but required in the local table
    // Set it to the current user's ID
    final userId = Store.currentUserId;
    if (userId == null) {
      throw StateError('Cannot sync priority_actor without authenticated user');
    }
    json['user_id'] = userId;
    return PriorityActorRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    // PriorityActor is read-only, so we don't need to convert to base format
    throw UnsupportedError('PriorityActor is read-only');
  }
}

class PriorityActor extends PriorityActorRow {
  static $PriorityActorsTable get table => Store.get.priorityActors;

  static Future<void> pull() async {
    // First pull: fetch all priority actors if not already initialized
    await Store.get.pull(table, PriorityActorsBase(), initial: true);
    // Subsequent pulls: fetch changes since last pull
    await Store.get.pull(table, PriorityActorsBase());
  }

  PriorityActor.fromStore(PriorityActorRow row)
    : super(
        userId: row.userId,
        priorityPath: row.priorityPath,
        actorId: row.actorId,
        updatedAt: row.updatedAt,
        pending: row.pending,
        createdAt: row.createdAt,
        archivedAt: row.archivedAt,
      );
}
