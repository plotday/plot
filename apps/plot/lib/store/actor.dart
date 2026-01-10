part of 'store.dart';

@DataClassName('ActorRow')
class Actors extends Table with SyncableTable, CreatedTable, DeletableTable {
  BlobColumn get id => blob().map(const ActorIdConverter())();
  TextColumn get type => text().map(const EnumConverter<ActorType>())();
  TextColumn get name => text()();
  TextColumn get email => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class ActorsBase extends BaseTable {
  ActorsBase() : super(table: 'user_actor');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    // Actor is read-only (synced from user_actor view), so we don't need to convert to base format
    throw UnsupportedError('Actor is read-only');
  }

  @override
  Insertable<ActorRow> fromBase(Map<String, dynamic> json) {
    return ActorRow.fromJson(json);
  }
}

class Actor extends ActorRow {
  static TableInfo<Actors, ActorRow> get table => Store.get.actors;

  // In-memory cache for Actor lookups
  static final Map<ActorId, Actor> _cache = {};

  /// Clear the entire Actor cache
  static void clearCache() {
    _cache.clear();
  }

  static Future<void> pull() async {
    // First pull: fetch all actors if not already initialized
    await Store.get.pull(table, ActorsBase(), initial: true);
    // Subsequent pulls: fetch changes since last pull
    await Store.get.pull(table, ActorsBase());
    // Clear cache to ensure fresh data is served
    clearCache();
  }

  static Future<List<Actor>> get({
    ActorId? id,
    Uuid? priorityId,
    String? priorityPath,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
  }) async {
    // Trigger archived sync if needed
    if (archived == true) {
      await Store.get.pullArchived(table, ActorsBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      await Store.get.pullArchived(table, ActorsBase());
    }

    // Convert priorityId to priorityPath for backward compatibility
    String? effectivePriorityPath = priorityPath;
    if (priorityId != null && priorityPath == null) {
      final priority = await Priority.getOne(priorityId);
      effectivePriorityPath = priority.path.value;
    }

    final actors = await _get(
      id: id,
      priorityPath: effectivePriorityPath,
      types: types,
      search: search,
      limit: limit,
      archived: archived,
    ).get();

    return actors;
  }

  static Stream<List<Actor>> watch({
    ActorId? id,
    Uuid? priorityId,
    String? priorityPath,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
  }) {
    // Trigger archived sync if needed
    if (archived == true) {
      Store.get.pullArchived(table, ActorsBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      Store.get.pullArchived(table, ActorsBase());
    }

    // Convert priorityId to priorityPath for backward compatibility
    // This needs to be done asynchronously, so we use a stream transformation
    if (priorityId != null && priorityPath == null) {
      return Stream.fromFuture(Priority.getOne(priorityId)).asyncExpand(
        (priority) => _get(
          id: id,
          priorityPath: priority.path.value,
          types: types,
          search: search,
          limit: limit,
          archived: archived,
        ).watch(),
      );
    }

    return _get(
      id: id,
      priorityPath: priorityPath,
      types: types,
      search: search,
      limit: limit,
      archived: archived,
    ).watch();
  }

  static Future<Actor> getOne(ActorId id) async {
    // Check cache first
    if (_cache.containsKey(id)) {
      return _cache[id]!;
    }

    // Cache miss - query database
    final actors = await _get(id: id, archived: null).get();
    if (actors.isEmpty) {
      throw Exception('Actor not found');
    }

    // Store in cache and return
    final actor = actors.first;
    _cache[id] = actor;
    return actor;
  }

  static Stream<Actor> watchOne(ActorId id) {
    return _get(id: id, archived: null).watch().map((actors) {
      if (actors.isEmpty) {
        throw Exception('Actor not found');
      }
      return actors.first;
    });
  }

  static MultiSelectable<Actor> _get({
    ActorId? id,
    String? priorityPath,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
  }) {
    final a = Store.get.actors;
    final pa = Store.get.priorityActors;

    // Build query with optional JOIN for priority filtering
    final query = priorityPath != null
        ? Store.get.select(a).join([
            innerJoin(
              pa,
              pa.actorId.equalsExp(a.id) &
                  (pa.priorityPath.equalsValue(Path(priorityPath)) | // Exact match
                      pa.priorityPath.likeExp(Constant('$priorityPath.%')) | // Children of requested path
                      Constant(priorityPath).likeExp(pa.priorityPath.dartCast<String>() + Constant('.%'))), // Ancestors (requested path is child of pa.priorityPath)
            ),
          ])
        : Store.get.select(a).join([]);

    // Apply archived filter
    if (archived == true) {
      query.where(a.archivedAt.isNotNull());
    } else if (archived == false) {
      query.where(a.archivedAt.isNull());
    }
    // archived == null means no filter (include all)

    // Filter by ID
    if (id != null) {
      query.where(a.id.equalsValue(id));
    }

    // Filter by actor types
    if (types != null && types.isNotEmpty) {
      final typeStrings = types.map((t) => (t as Enum).name.toSnakeCase()).toList();
      query.where(a.type.isIn(typeStrings));
    }

    // Search by name or email (case-insensitive with LIKE)
    if (search != null && search.isNotEmpty) {
      final searchPattern = '%${search.toLowerCase()}%';
      query.where(
        a.name.like(searchPattern) | a.email.like(searchPattern),
      );
    }

    // Apply limit
    if (limit != null) {
      query.limit(limit);
    }

    // Map results, reading from the joined query
    return query.map((row) => Actor.fromStore(row.readTable(a)));
  }

  Actor.fromStore(ActorRow row)
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        type: row.type,
        name: row.name,
        email: row.email,
        avatarUrl: row.avatarUrl,
      );

  @override
  Actor copyWith({
    ActorId? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    ActorType? type,
    String? name,
    Value<String?> email = const Value.absent(),
    Value<String?> avatarUrl = const Value.absent(),
    Value<int?> pending = const Value.absent(),
  }) => Actor.fromStore(
    super.copyWith(
      id: id,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      archivedAt: archivedAt,
      type: type,
      name: name,
      email: email,
      avatarUrl: avatarUrl,
      pending: pending,
    ),
  );
}

/// Drift converter for ActorId
class ActorIdConverter extends TypeConverter<ActorId, Uint8List>
    with JsonTypeConverter2<ActorId, Uint8List, String> {
  const ActorIdConverter();

  @override
  ActorId fromSql(Uint8List fromDb) {
    return ActorId.fromUuid(Uuid.fromBytes(fromDb));
  }

  @override
  Uint8List toSql(ActorId value) {
    return value.toUuid().toBytes();
  }

  @override
  ActorId fromJson(String json) {
    return ActorId.fromString(json);
  }

  @override
  String toJson(ActorId value) {
    return value.toString();
  }
}

/// Drift converter for lists of ActorIds
class ActorIdListConverter extends TypeConverter<List<ActorId>, String>
    with JsonTypeConverter2<List<ActorId>, String, List<dynamic>> {
  const ActorIdListConverter();

  @override
  List<ActorId> fromSql(String fromDb) {
    if (fromDb.isEmpty) return [];
    return fromDb
        .split(',')
        .map((uuidStr) => ActorId.fromString(uuidStr.trim()))
        .toList();
  }

  @override
  String toSql(List<ActorId> value) {
    return value.map((id) => id.toString()).join(',');
  }

  @override
  List<ActorId> fromJson(List<dynamic> json) {
    return json.map((item) => ActorId.fromString(item as String)).toList();
  }

  @override
  List<dynamic> toJson(List<ActorId> value) {
    return value.map((id) => id.toString()).toList();
  }
}
