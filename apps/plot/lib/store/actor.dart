part of 'store.dart';

@DataClassName('ActorRow')
class Actors extends Table with SyncableTable, CreatedTable, DeletableTable {
  BlobColumn get id => blob().map(const ActorIdConverter())();
  TextColumn get type => text().map(const EnumConverter<ActorType>())();
  TextColumn get name => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  BoolColumn get self => boolean()();

  @override
  Set<Column> get primaryKey => {id};
}

class ActorsBase extends BaseTable {
  ActorsBase() : super(table: 'user_actor', syncEndpoint: 'actors');

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
    // Repopulate cache with critical actors (self + twists)
    await pullCritical();
  }

  /// Loads only critical actors into cache: self actors and priority twists.
  /// Other actors are cached lazily when accessed via get() or getOne().
  static Future<void> pullCritical() async {
    try {
      await Future(() async {
        // Query 1: Fetch only actors with self = true (user's own actors)
        // Typically 1-10 actors (user's email addresses across different contacts)
        await get(self: true, archived: null);

        // Query 2: Fetch only priority twist actors
        // Typically < 50 actors (one per active twist)
        await get(types: [ActorType.twistInstance], archived: null);

        // Both queries automatically populate the cache via get() (lines 84-87)
      }).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      log.warning("Actor.pullCritical timed out after 10s — continuing with local data");
      Tracker.trackError(
        'auth',
        errorType: 'TimeoutException',
        errorMessage: 'Actor.pullCritical timed out after 10s',
        context: 'sign_in_actor_pull_timeout',
      );
    }
  }

  static Future<List<Actor>> get({
    ActorId? id,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
    bool? self,
  }) async {
    // Trigger archived sync if needed
    if (archived == true) {
      await Store.get.pullArchived(table, ActorsBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      await Store.get.pullArchived(table, ActorsBase());
    }

    final actors = await _get(
      id: id,
      types: types,
      search: search,
      limit: limit,
      archived: archived,
      self: self,
    ).get();

    // Cache all fetched actors for synchronous lookups
    for (final actor in actors) {
      _cache[actor.id] = actor;
    }

    return actors;
  }

  static Stream<List<Actor>> watch({
    ActorId? id,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
    bool? self,
  }) {
    // Trigger archived sync if needed
    if (archived == true) {
      Store.get.pullArchived(table, ActorsBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      Store.get.pullArchived(table, ActorsBase());
    }

    return _get(
      id: id,
      types: types,
      search: search,
      limit: limit,
      archived: archived,
      self: self,
    ).watch();
  }

  /// Synchronous cache lookup. Returns null if the actor has not yet
  /// been fetched into the in-memory cache.
  static Actor? fromCache(ActorId id) => _cache[id];

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

  /// Returns non-self, non-archived user/contact actors ordered for thread
  /// sharing:
  ///   1. MRU — actors who appear on the user's most-recent threads, ordered
  ///      by the recency of their most-recent thread.
  ///   2. Frequent — remaining actors on any of the user's threads, ordered
  ///      by thread count (ties → alphabetical).
  ///   3. Rest — all other matching actors, alphabetical.
  ///
  /// The candidate pool honors [search] via the same LIKE filter as [get].
  static Future<List<Actor>> getSortedForSharing({
    String? search,
    int mruSize = 5,
    int threadWindow = 200,
  }) async {
    final candidates = await get(
      types: [ActorType.user, ActorType.contact],
      search: search,
    );
    candidates.removeWhere((a) => a.self);

    final selfIds = getCurrentUserActorIds().map((a) => a.toUuid()).toSet();
    final threads = await Thread.get(
      draft: false,
      archived: false,
      order: ThreadOrder.reverse,
      limit: threadWindow,
    );

    // Walk threads newest-first; first sighting of a contact is their MRU.
    final firstSeenIndex = <Uuid, int>{};
    final counts = <Uuid, int>{};
    for (var i = 0; i < threads.length; i++) {
      for (final contactId in threads[i].contacts) {
        if (selfIds.contains(contactId)) continue;
        firstSeenIndex.putIfAbsent(contactId, () => i);
        counts[contactId] = (counts[contactId] ?? 0) + 1;
      }
    }

    int byName(Actor a, Actor b) =>
        a.nameOrEmail.toLowerCase().compareTo(b.nameOrEmail.toLowerCase());

    final seen = <Actor>[];
    final unseen = <Actor>[];
    for (final actor in candidates) {
      if (firstSeenIndex.containsKey(actor.id.toUuid())) {
        seen.add(actor);
      } else {
        unseen.add(actor);
      }
    }

    // MRU: order seen actors by first-seen index (lower = more recent).
    seen.sort((a, b) {
      final ai = firstSeenIndex[a.id.toUuid()]!;
      final bi = firstSeenIndex[b.id.toUuid()]!;
      if (ai != bi) return ai.compareTo(bi);
      return byName(a, b);
    });

    final mru = seen.take(mruSize).toList();
    final frequent = seen.skip(mruSize).toList()
      ..sort((a, b) {
        final ca = counts[a.id.toUuid()] ?? 0;
        final cb = counts[b.id.toUuid()] ?? 0;
        if (ca != cb) return cb.compareTo(ca);
        return byName(a, b);
      });
    unseen.sort(byName);

    return [...mru, ...frequent, ...unseen];
  }

  /// Returns all actor IDs that belong to the current user.
  /// Uses the Actor cache for synchronous lookup.
  /// Falls back to Base.actorId if cache is empty, or returns empty list
  /// if actorId is not yet available.
  static List<ActorId> getCurrentUserActorIds() {
    final userActorIds = _cache.values
        .where((actor) => actor.self)
        .map((actor) => actor.id)
        .toList();

    // Fallback to Base.actorId if cache is empty
    if (userActorIds.isEmpty) {
      final id = Base.actorIdOrNull;
      if (id != null) return [id];
      return [];
    }

    return userActorIds;
  }

  /// Get Actor by auth user ID (via contact.user_id lookup).
  /// Returns null if no contact is found for the given user ID.
  // TODO: Add API endpoint to look up contact by user_id, or sync user_id to local actors table
  static Future<Actor?> getByUserId(Uuid userId) async {
    try {
      final result = await api.get<List<dynamic>>(
        '/contact/by-user/${userId.toString()}',
      );
      if (result.isEmpty) return null;

      final contactId = result.first['id'] as String;
      final actorId = ActorId.fromString(contactId);

      return await getOne(actorId);
    } catch (e) {
      return null;
    }
  }

  static MultiSelectable<Actor> _get({
    ActorId? id,
    List<ActorType>? types,
    String? search,
    int? limit,
    bool? archived = false,
    bool? self,
  }) {
    final a = Store.get.actors;
    final query = Store.get.select(a).join([]);

    // Apply archived filter
    if (archived == true) {
      query.where(a.archivedAt.isNotNull());
    } else if (archived == false) {
      query.where(a.archivedAt.isNull());
    }
    // archived == null means no filter (include all)

    // Exclude contacts with no name and no email (they'd show as "Unknown")
    // Skip this filter when querying by specific ID (e.g. resolving note authors)
    if (id == null) {
      query.where(
        a.name.isNotNull() | a.email.isNotNull(),
      );
    }

    // Filter by ID
    if (id != null) {
      query.where(a.id.equalsValue(id));
    }

    // Filter by actor types
    if (types != null && types.isNotEmpty) {
      final typeStrings = types
          .map((t) => (t as Enum).name.toSnakeCase())
          .toList();
      query.where(a.type.isIn(typeStrings));
    }

    // Filter by self flag
    if (self != null) {
      query.where(a.self.equals(self));
    }

    // Search by name or email (case-insensitive with LIKE)
    if (search != null && search.isNotEmpty) {
      final searchPattern = '%${search.toLowerCase()}%';
      query.where(a.name.like(searchPattern) | a.email.like(searchPattern));
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
        self: row.self,
      );

  @override
  Actor copyWith({
    ActorId? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    ActorType? type,
    Value<String?> name = const Value.absent(),
    Value<String?> email = const Value.absent(),
    Value<String?> avatarUrl = const Value.absent(),
    bool? self,
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
      self: self,
      pending: pending,
    ),
  );

  /// Returns the actor's name if available, otherwise their email
  String get nameOrEmail {
    if (name != null && name!.isNotEmpty) {
      return name!;
    }
    return email ?? 'Unknown';
  }
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

/// Extension methods for ActorId to check if it belongs to the current user
extension ActorIdHelpers on ActorId {
  /// Synchronous version - checks if this ActorId belongs to the current user.
  /// Only use when Actor data is guaranteed to be cached (after startup sync).
  /// Falls back to checking against the primary contact if Actor not cached.
  bool get isCurrentUser {
    final actor = Actor._cache[this];
    if (actor == null) {
      // Fallback to primary contact check if not in cache
      return this == Base.actorId;
    }
    return actor.self;
  }

  /// Check if this actor is a twist (twistInstance type).
  /// Uses TwistInstance cache for synchronous lookup - returns false if not cached.
  /// Note: TwistInstance.id IS the ActorId for twists.
  bool get isTwist {
    // Convert ActorId to Uuid since TwistInstance._cache uses TwistInstanceId (Uuid)
    final twistId = toUuid();
    return TwistInstance._cache.containsKey(twistId);
  }
}
