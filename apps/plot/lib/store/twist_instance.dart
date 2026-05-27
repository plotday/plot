part of 'store.dart';

typedef TwistInstanceId = Uuid;

@DataClassName('TwistInstanceRow')
class TwistInstances extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  Int64Column get twistId => int64()(); // Changed from UUID to bigint
  TextColumn get twistEnvironment =>
      text()(); // Read from user_twist view (JOIN with twist table)
  Int64Column get teamId => int64().nullable()();
  BoolColumn get draft => boolean().withDefault(const Constant(false))();
  BoolColumn get isSource => boolean().withDefault(const Constant(false))();
  BoolColumn get shared => boolean().withDefault(const Constant(false))();
  TextColumn get keyOption => text().nullable()();
  TextColumn get name => text()();
  TextColumn get handle => text().withDefault(const Constant(''))();
  TextColumn get threadType => text().nullable()();
  TextColumn get accountLabel => text().nullable()();
  TextColumn get config => text().map(const JsonConverter())();
  TextColumn get linkTypes => text().nullable()();
  TextColumn get logoUrl => text().nullable()();
  TextColumn get logoUrlDark => text().nullable()();
  BoolColumn get defaultMentionCreated => boolean().withDefault(const Constant(false))();
  BoolColumn get defaultMentionMentioned => boolean().withDefault(const Constant(false))();
  BoolColumn get userConnected => boolean().withDefault(const Constant(false))();
  BoolColumn get isBuiltin => boolean().withDefault(const Constant(false))();
  BoolColumn get multipleInstances => boolean().withDefault(const Constant(false))();
}

class TwistInstancesBase extends BaseTable {
  TwistInstancesBase()
    : super(
        table: 'user_twist',
        syncEndpoint: 'twist-instances',
        name: "twist_instances",
        order: 'created_at',
        ascending: false,
      );

  @override
  Insertable<TwistInstanceRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('owner_id');
    json.remove('user_id');
    // The user.twist view uses 'options' but Drift expects 'config'
    if (json.containsKey('options') && !json.containsKey('config')) {
      json['config'] = json.remove('options');
    }
    // Default missing boolean fields not present in the view
    json['draft'] ??= false;
    // Serialize link_types JSON to string for text column storage
    if (json['link_types'] != null && json['link_types'] is! String) {
      json['link_types'] = jsonEncode(json['link_types']);
    }
    // Drift's default serializer can't cast int/String to BigInt; convert explicitly.
    // pg driver may return bigint as int (with type parser) or String (without).
    final twistId = json['twist_id'];
    if (twistId is int) {
      json['twist_id'] = BigInt.from(twistId);
    } else if (twistId is String) {
      json['twist_id'] = BigInt.parse(twistId);
    }
    final teamId = json['team_id'];
    if (teamId is int) {
      json['team_id'] = BigInt.from(teamId);
    } else if (teamId is String) {
      json['team_id'] = BigInt.parse(teamId);
    }
    return TwistInstanceRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('user_id');
    return json;
  }
}

class TwistInstance extends TwistInstanceRow {
  static $TwistInstancesTable get table => Store.get.twistInstances;

  // In-memory cache for TwistInstance lookups
  static final Map<TwistInstanceId, TwistInstance> _cache = {};

  /// Look up a TwistInstance by ID from the in-memory cache.
  /// Returns null if the twist is not cached.
  static TwistInstance? fromCache(TwistInstanceId id) => _cache[id];

  /// Find a TwistInstance by its twist ID (bigint) from the in-memory cache.
  /// Returns the first match or null if not found.
  static TwistInstance? findByTwistId(BigInt twistId) {
    return _cache.values.where((pt) => pt.twistId == twistId).firstOrNull;
  }

  /// Clear the entire TwistInstance cache
  static void clearCache() {
    _cache.clear();
  }

  // Static subscription for global cache watch
  static StreamSubscription<List<TwistInstance>>? _globalWatchSubscription;

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

  static Future<bool> push() => Store.get.push(table, TwistInstancesBase());

  /// Bounded single-pass pull used by `_twistInstanceCritical` in the
  /// critical initial-sync path. Keep this fast: a fresh-client sign-in for
  /// an existing account runs this against `seq=0`, and the whole critical
  /// phase must fit inside ~30s. If you need to do additional work for
  /// twist instances on first sync, add it to `pullUpdates` (which runs in
  /// `syncInitialDeferred`) rather than expanding this method. See
  /// `SyncOrchestrator._criticalEntities` for the invariant.
  static Future<void> pullInitial() async {
    await Store.get.pull(table, TwistInstancesBase(), initial: true);
  }

  static Future<void> pull() async {
    await pullInitial();
    await pullUpdates();
  }

  static Future<void> pullUpdates() async {
    await Store.get.pull(table, TwistInstancesBase());
  }

  static Future<List<TwistInstance>> get({bool? archived = false}) async {
    final query = _get(archived: archived);
    final rows = await query.get();
    final twists = rows.map((row) => TwistInstance(row)).toList();
    // Cache all fetched twists for synchronous lookups
    for (final twist in twists) {
      _cache[twist.id] = twist;
    }
    return twists;
  }

  static Stream<List<TwistInstance>> watch({bool? archived = false}) {
    // Defensive check: Return empty stream if Store is not available (user signing out)
    if (!Injector.appInstance.exists<Store>()) {
      return Stream.value([]);
    }
    final query = _get(archived: archived);
    return query.watch().map((rows) {
      final twists = rows.map((row) => TwistInstance(row)).toList();
      // Cache all watched twists for synchronous lookups
      for (final twist in twists) {
        _cache[twist.id] = twist;
      }
      return twists;
    });
  }

  static SimpleSelectStatement<$TwistInstancesTable, TwistInstanceRow> _get({
    bool? archived = false,
  }) {
    final query = Store.get.select(table)
      ..where((t) => t.draft.equals(false));

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

  /// Watch source accounts (all active, non-draft source twists).
  static Stream<List<TwistInstance>> watchSourceAccounts() {
    // Defensive check: Return empty stream if Store is not available (user signing out)
    if (!Injector.appInstance.exists<Store>()) {
      return Stream.value([]);
    }
    final query = Store.get.select(table)
      ..where((t) => t.draft.equals(false))
      ..where((t) => t.isSource.equals(true))
      ..where((t) => t.archivedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    return query.watch().map((rows) {
      final twists = rows.map((row) => TwistInstance(row)).toList();
      for (final twist in twists) {
        _cache[twist.id] = twist;
      }
      return twists;
    });
  }

  TwistInstance(TwistInstanceRow row)
    : super(
        id: row.id,
        twistId: row.twistId,
        twistEnvironment: row.twistEnvironment,
        teamId: row.teamId,
        draft: row.draft,
        isSource: row.isSource,
        shared: row.shared,
        keyOption: row.keyOption,
        name: row.name,
        handle: row.handle,
        threadType: row.threadType,
        accountLabel: row.accountLabel,
        config: row.config,
        linkTypes: row.linkTypes,
        logoUrl: row.logoUrl,
        logoUrlDark: row.logoUrlDark,
        defaultMentionCreated: row.defaultMentionCreated,
        defaultMentionMentioned: row.defaultMentionMentioned,
        userConnected: row.userConnected,
        isBuiltin: row.isBuiltin,
        multipleInstances: row.multipleInstances,
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

  /// Returns the display name for this twist instance.
  ///
  /// For sources (connections), the per-connection [accountLabel] is appended
  /// so notes/mentions show e.g. `Gmail (kris@plot.day)` — the same format the
  /// server-side `actor` view produces.
  ///
  /// For single-instance twists, if the user has the same twist (same [twistId])
  /// installed in multiple scopes (e.g. Personal + a team), appends a scope
  /// suffix so the user can distinguish them:
  ///   - Personal scope → "Claude (Personal)"
  ///   - Team scope     → "Claude (Acme)"
  ///
  /// [allInstances] should be all active, non-archived TwistInstance rows for
  /// the current user. [teamName] is the display name of the team that owns
  /// this instance (null for personal).
  String displayName({
    required List<TwistInstance> allInstances,
    String? teamName,
  }) {
    // Sources: compose with account_label for note-author / mention display.
    if (isSource) {
      if (accountLabel != null && accountLabel!.isNotEmpty) {
        return '$name ($accountLabel)';
      }
      return name;
    }

    // Multi-instance twists always use their configured name as-is
    if (multipleInstances) return name;

    // Check if any sibling instance shares the same twist package
    final hasSibling = allInstances.any(
      (other) =>
          other.id != id &&
          other.twistId == twistId &&
          other.archivedAt == null,
    );

    if (!hasSibling) return name;

    final scopeLabel = teamId == null ? 'Personal' : (teamName ?? 'Team');
    return '$name ($scopeLabel)';
  }

  /// At-mention / attribution label for this twist.
  ///
  /// Mirrors [displayName] but uses [handle] (the package-level mention
  /// name) as the base instead of [name] (the per-install display name).
  /// Sources keep using their per-connection [accountLabel] suffix.
  /// Multi-instance and scope-disambiguation rules match [displayName] so
  /// the label is unique across the user's installed twists.
  String mentionLabel({
    required List<TwistInstance> allInstances,
    String? teamName,
  }) {
    final base = handle.isEmpty ? name : handle;
    if (isSource) {
      if (accountLabel != null && accountLabel!.isNotEmpty) {
        return '$base ($accountLabel)';
      }
      return base;
    }
    if (multipleInstances) return base;
    final hasSibling = allInstances.any(
      (other) =>
          other.id != id &&
          other.twistId == twistId &&
          other.archivedAt == null,
    );
    if (!hasSibling) return base;
    final scopeLabel = teamId == null ? 'Personal' : (teamName ?? 'Team');
    return '$base ($scopeLabel)';
  }

  Future<void> save() async {
    await Store.get.save(
      table,
      copyWith(updatedAt: DateTime.now()),
      TwistInstancesBase(),
    );
  }
}
