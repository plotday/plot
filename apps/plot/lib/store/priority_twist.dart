part of 'store.dart';

typedef PriorityTwistId = Uuid;

@DataClassName('PriorityTwistRow')
class PriorityTwists extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  BlobColumn get priorityId =>
      blob().nullable().map(const UuidConverter())();
  Int64Column get twistId => int64()(); // Changed from UUID to bigint
  TextColumn get twistEnvironment =>
      text()(); // Read from user_twist view (JOIN with twist table)
  BoolColumn get isSource => boolean().withDefault(const Constant(false))();
  TextColumn get name => text()();
  TextColumn get config => text().map(const JsonConverter())();
  TextColumn get linkTypes => text().nullable()();
  TextColumn get logoUrl => text().nullable()();
  TextColumn get logoUrlDark => text().nullable()();
  BoolColumn get defaultMentionCreated => boolean().withDefault(const Constant(false))();
  BoolColumn get defaultMentionMentioned => boolean().withDefault(const Constant(false))();
  BoolColumn get userConnected => boolean().withDefault(const Constant(false))();
}

class PriorityTwistsBase extends BaseTable {
  PriorityTwistsBase()
    : super(
        table: 'user_twist',
        syncEndpoint: 'priority-twists',
        name: "priority_twists",
        order: 'created_at',
        ascending: false,
      );

  @override
  Insertable<PriorityTwistRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('owner_id');
    json.remove('user_id');
    // Serialize link_types JSON to string for text column storage
    if (json['link_types'] != null && json['link_types'] is! String) {
      json['link_types'] = jsonEncode(json['link_types']);
    }
    return PriorityTwistRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('user_id');
    return json;
  }
}

class PriorityTwist extends PriorityTwistRow {
  static $PriorityTwistsTable get table => Store.get.priorityTwists;

  // In-memory cache for PriorityTwist lookups
  static final Map<PriorityTwistId, PriorityTwist> _cache = {};

  /// Look up a PriorityTwist by ID from the in-memory cache.
  /// Returns null if the twist is not cached.
  static PriorityTwist? fromCache(PriorityTwistId id) => _cache[id];

  /// Clear the entire PriorityTwist cache
  static void clearCache() {
    _cache.clear();
  }

  // Static subscription for global cache watch
  static StreamSubscription<List<PriorityTwist>>? _globalWatchSubscription;

  /// Start watching all priority twists globally to populate the cache.
  /// This enables synchronous isTwist checks from any context.
  static Future<void> start() async {
    _globalWatchSubscription?.cancel();
    final completer = Completer<void>();
    _globalWatchSubscription = watch().listen((twists) {
      // Cache is populated automatically by watch()
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  /// Stop the global watch.
  static void stopGlobalWatch() {
    _globalWatchSubscription?.cancel();
    _globalWatchSubscription = null;
    clearCache();
  }

  static Future<bool> push() => Store.get.push(table, PriorityTwistsBase());

  static Future<void> pullInitial() async {
    await Store.get.pull(table, PriorityTwistsBase(), initial: true);
  }

  static Future<void> pull() async {
    await pullInitial();
    await pullUpdates();
  }

  static Future<void> pullUpdates() async {
    await Store.get.pull(table, PriorityTwistsBase());
  }

  static Future<List<PriorityTwist>> get({
    PriorityId? priorityId,
    Priority? priority,
    bool includeAncestors = true,
    bool? archived = false,
  }) async {
    final query = _get(
      priorityId: priorityId,
      priority: priority,
      includeAncestors: includeAncestors,
      archived: archived,
    );
    final rows = await query.get();
    final twists = rows.map((row) => PriorityTwist(row)).toList();
    // Cache all fetched twists for synchronous lookups
    for (final twist in twists) {
      _cache[twist.id] = twist;
    }
    return twists;
  }

  static Stream<List<PriorityTwist>> watch({
    PriorityId? priorityId,
    Priority? priority,
    bool includeAncestors = true,
    bool? archived = false,
  }) {
    final query = _get(
      priorityId: priorityId,
      priority: priority,
      includeAncestors: includeAncestors,
      archived: archived,
    );
    return query.watch().map((rows) {
      final twists = rows.map((row) => PriorityTwist(row)).toList();
      // Cache all watched twists for synchronous lookups
      for (final twist in twists) {
        _cache[twist.id] = twist;
      }
      return twists;
    });
  }

  static SimpleSelectStatement<$PriorityTwistsTable, PriorityTwistRow> _get({
    PriorityId? priorityId,
    Priority? priority,
    bool includeAncestors = true,
    bool? archived = false,
  }) {
    final query = Store.get.select(table);

    if (priority != null && includeAncestors) {
      // Get all ancestor IDs plus the current priority ID
      final ancestors = priority.ancestors(includeSelf: true);
      final priorityIds = ancestors.map((a) => a.id.toBytes()).toList();

      // The ancestors() method skips the root priority for display,
      // but we need it for twist queries
      if (priority._ancestors.isNotEmpty) {
        final rootId = priority._ancestors.first.id.toBytes();
        priorityIds.insert(0, rootId);
      }

      query.where((t) => t.priorityId.isIn(priorityIds));
    } else if (priority != null) {
      // Just the priority itself, no ancestors
      query.where((t) => t.priorityId.equals(priority.id.toBytes()));
    } else if (priorityId != null) {
      // Legacy: using priorityId directly
      query.where((t) => t.priorityId.equals(priorityId.toBytes()));
    }

    if (archived != null) {
      if (archived) {
        query.where((t) => t.archivedAt.isNotNull());
      } else {
        query.where((t) => t.archivedAt.isNull());
      }
    }

    query.orderBy([(t) => OrderingTerm.desc(t.createdAt)]);

    return query;
  }

  /// Watch source accounts (sources with no priority, i.e. account-based).
  static Stream<List<PriorityTwist>> watchSourceAccounts() {
    final query = Store.get.select(table)
      ..where((t) => t.priorityId.isNull())
      ..where((t) => t.isSource.equals(true))
      ..where((t) => t.archivedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    return query.watch().map((rows) {
      final twists = rows.map((row) => PriorityTwist(row)).toList();
      for (final twist in twists) {
        _cache[twist.id] = twist;
      }
      return twists;
    });
  }

  PriorityTwist(PriorityTwistRow row)
    : super(
        id: row.id,
        priorityId: row.priorityId,
        twistId: row.twistId,
        twistEnvironment: row.twistEnvironment,
        isSource: row.isSource,
        name: row.name,
        config: row.config,
        linkTypes: row.linkTypes,
        logoUrl: row.logoUrl,
        logoUrlDark: row.logoUrlDark,
        defaultMentionCreated: row.defaultMentionCreated,
        defaultMentionMentioned: row.defaultMentionMentioned,
        userConnected: row.userConnected,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        pending: row.pending,
      );

  /// Parse the linkTypes JSON string into a list of LinkTypeConfig.
  List<LinkTypeConfig>? get parsedLinkTypes {
    final raw = linkTypes;
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => LinkTypeConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    await Store.get.save(
      table,
      copyWith(updatedAt: DateTime.now()),
      PriorityTwistsBase(),
    );
  }
}
