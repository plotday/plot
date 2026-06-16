part of 'store.dart';

typedef RoleId = Uuid;

/// A role groups a user's focuses ([Priorities]) and carries a colour and a
/// notification template that its focuses follow (server-side propagation;
/// see `libs/db/schema/95-triggers/30-role-propagation.sql`). One row per role
/// per user. Roles are a flat, single-level grouping — there is no nesting.
///
/// Synced from `user.role` via `/sync/roles`. Mirrors the [Priorities] sync
/// conventions (seq cursor, soft-delete via `archived_at`).
@DataClassName('RoleRow')
class Roles extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  BlobColumn get createdBy => blob().map(const UuidConverter())();
  TextColumn get name => text()();
  IntColumn get color =>
      integer().nullable().map(const ThemeColorConverter())();
  RealColumn get order => real().nullable().map(const OrderConverter())();

  /// Master toggle for the role's "Early notifications" mechanism. Focuses in
  /// the role follow this value until overridden. Mirrors the per-focus column
  /// on [Priorities].
  BoolColumn get earlyNotificationsEnabled => boolean().nullable()();

  /// Active hours during which early notifications may fire. JSON-encoded
  /// `List<AttentionWindow>` stored as TEXT (server sends native JSON).
  TextColumn get notifyWindow => text().nullable()();

  /// "See within" time the role's focuses follow. JSON-encoded stored as TEXT.
  TextColumn get seeWithin => text().nullable()();
}

class RolesBase extends BaseTable {
  RolesBase()
    : super(
        table: 'user_role',
        syncEndpoint: 'roles',
        name: 'roles',
        order: 'created_at',
      );

  @override
  Insertable<RoleRow> fromBase(Map<String, dynamic> json) {
    // `user.role` carries the owning user_id; the Drift table doesn't model it
    // (mirrors PrioritiesBase stripping `updated_by`).
    json.remove('user_id');
    // The server sends notify_window/see_within as native JSON; Drift stores
    // them as TEXT, so encode any non-string value (mirrors PrioritiesBase).
    for (final key in const ['notify_window', 'see_within']) {
      final value = json[key];
      if (value != null && value is! String) {
        json[key] = jsonEncode(value);
      }
    }
    return RoleRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    // Decode TEXT-stored windows back to JSON for the wire so upsert_role's
    // jsonb extraction (`p_role -> 'notify_window'`) sees an array/object, not
    // a string.
    for (final key in const ['notify_window', 'see_within']) {
      final value = json[key];
      if (value is String) {
        json[key] = jsonDecode(value);
      }
    }
    return json;
  }
}

/// Convenience wrapper over [RoleRow] mirroring the [Priority] idiom: subclass
/// the generated row so callers can pass a `Role` anywhere a `RoleRow` is
/// expected, plus a few derived getters.
class Role extends RoleRow {
  Role._(RoleRow row)
    : super(
        id: row.id,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        pending: row.pending,
        archivedAt: row.archivedAt,
        createdBy: row.createdBy,
        name: row.name,
        color: row.color,
        order: row.order,
        earlyNotificationsEnabled: row.earlyNotificationsEnabled,
        notifyWindow: row.notifyWindow,
        seeWithin: row.seeWithin,
      );

  /// Builds an unsaved role with a client-generated id and the current user as
  /// author. [order] defaults to the current epoch millis so a newly created
  /// role sorts to the bottom of the sidebar list. Notification fields are left
  /// unset (the server seeds the role's Inbox and defaults). Call [save] to
  /// persist (pushes to `/sync/roles`).
  factory Role.create({
    required String name,
    ThemeColor? color,
    Order? order,
  }) {
    final now = DateTime.now();
    return Role._(
      RoleRow(
        id: Uuid.generate(),
        createdBy: Base.userId,
        createdAt: now,
        updatedAt: now,
        name: name,
        color: color,
        order: order ?? Order(now.millisecondsSinceEpoch.toDouble()),
      ),
    );
  }

  /// Wraps a raw [RoleRow] as a [Role] without touching the store. Test-only —
  /// production builds roles via [Role.create] or the store watch ([_wrap]).
  @visibleForTesting
  factory Role.fromRow(RoleRow row) => Role._(row);

  static $RolesTable get table => Store.get.roles;

  static Role _wrap(RoleRow row) => Role._(row);

  // ---------------------------------------------------------------------------
  // Synchronous, reactive cache
  //
  // Lets stateless widgets (e.g. [FocusLabel]) render a focus's `[Role] ›`
  // prefix synchronously — and rebuild when roles change — without a per-row
  // async query. Mirrors [Priority]'s snapshot+watch cache and [Actor]'s
  // lookup cache. The list is the user's non-archived roles, sorted as the
  // sidebar shows them.
  // ---------------------------------------------------------------------------

  static final ValueNotifier<List<Role>> _cacheNotifier =
      ValueNotifier<List<Role>>(const []);
  static final Map<RoleId, Role> _cacheById = {};
  static StreamSubscription<List<Role>>? _cacheWatch;

  /// Reactive list of the user's non-archived roles, kept current by a single
  /// watch started lazily on first access. Empty until the first emission.
  /// Listenable so stateless widgets can rebuild when roles are added, renamed,
  /// recoloured, or removed.
  static ValueListenable<List<Role>> get cache {
    _ensureCacheWatch();
    return _cacheNotifier;
  }

  /// Number of non-archived roles currently known. Used to gate the focus
  /// role prefix: it is only shown when the user has more than one role.
  static int get cachedCount {
    _ensureCacheWatch();
    return _cacheNotifier.value.length;
  }

  /// Synchronous role lookup from the warm [cache]. Returns null when [id] is
  /// null or the role hasn't been cached yet.
  static Role? fromCache(RoleId? id) {
    if (id == null) return null;
    _ensureCacheWatch();
    return _cacheById[id];
  }

  static void _ensureCacheWatch() {
    if (_cacheWatch != null) return;
    // The watch reads the local store; skip until it exists (e.g. before
    // sign-in). A later access retries once the store is up.
    if (!Injector.appInstance.exists<Store>()) return;
    _cacheWatch = watch().listen((roles) {
      _cacheById
        ..clear()
        ..addEntries(roles.map((r) => MapEntry(r.id, r)));
      _cacheNotifier.value = roles;
    });
  }

  /// Clears the role cache and stops its watch. Call on sign-out / store reset
  /// (mirrors [Actor.clearCache] / [Priority.clearCache]).
  static void clearCache() {
    _cacheWatch?.cancel();
    _cacheWatch = null;
    _cacheById.clear();
    _cacheNotifier.value = const [];
  }

  /// The role's colour, defaulting to the theme default when unset.
  ThemeColor get displayColor => color ?? const ThemeColor.defaultColor();

  /// Parsed "notify during" windows the role's focuses follow.
  List<AttentionWindow>? get notifyWindows =>
      AttentionWindow.fromJsonString(notifyWindow);

  /// Parsed "see within" time the role's focuses follow.
  SeeWithinTime? get seeWithinTime => SeeWithinTime.fromJsonString(seeWithin);

  static Future<bool> push() => Store.get.push(table, RolesBase());

  static Future<void> pull() async {
    // First pull: fetch all roles if not already initialized.
    await Store.get.pull(table, RolesBase(), initial: true);
    // Subsequent pulls: fetch changes since last pull.
    await Store.get.pull(table, RolesBase());
  }

  /// Live list of roles, sorted by sidebar [order] then creation time.
  static Stream<List<Role>> watch({bool? archived = false}) {
    if (!Injector.appInstance.exists<Store>()) {
      return Stream.value([]);
    }
    final query = Store.get.select(table);
    if (archived != null) {
      query.where(
        (t) => archived ? t.archivedAt.isNotNull() : t.archivedAt.isNull(),
      );
    }
    query.orderBy([
      (t) => OrderingTerm(expression: t.order),
      (t) => OrderingTerm(expression: t.createdAt),
    ]);
    return query.watch().map((rows) => rows.map(_wrap).toList());
  }

  /// All roles, sorted by sidebar [order] then creation time.
  static Future<List<Role>> all({bool? archived = false}) async {
    final query = Store.get.select(table);
    if (archived != null) {
      query.where(
        (t) => archived ? t.archivedAt.isNotNull() : t.archivedAt.isNull(),
      );
    }
    query.orderBy([
      (t) => OrderingTerm(expression: t.order),
      (t) => OrderingTerm(expression: t.createdAt),
    ]);
    return (await query.get()).map(_wrap).toList();
  }

  /// True when the user has configured roles beyond the seeded default — more
  /// than one role, or a single role renamed away from the seeded 'Personal'.
  /// A second-device "already onboarded" signal for the rare case where the
  /// synced `onboarding_completed` flag hasn't landed yet (e.g. device 1
  /// finished onboarding offline): the role-question step renames the role but
  /// creates no non-root focus, so [Priority.hasNonRoot] alone wouldn't fire.
  static Future<bool> hasConfigured() async {
    final roles = await all();
    if (roles.length > 1) return true;
    return roles.length == 1 && roles.first.name != 'Personal';
  }

  /// Fetch a single role by id. Returns null if it hasn't synced yet.
  static Future<Role?> getOne(RoleId id) async {
    final row =
        await (Store.get.select(table)
              ..where((t) => t.id.equals(id.toBytes()))
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _wrap(row);
  }

  /// Watch a single role by id. Emits null until the role is synced.
  static Stream<Role?> watchOne(RoleId id) {
    return (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes()))
          ..limit(1))
        .watchSingleOrNull()
        .map((row) => row == null ? null : _wrap(row));
  }

  /// Returns a [Role] (not a bare [RoleRow]) so callers can chain [save].
  /// Mirrors [Priority.copyWith]'s subclass-preserving override.
  @override
  Role copyWith({
    DateTime? updatedAt,
    Value<int?> pending = const Value.absent(),
    Uuid? id,
    DateTime? createdAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    Uuid? createdBy,
    String? name,
    Value<ThemeColor?> color = const Value.absent(),
    Value<Order?> order = const Value.absent(),
    Value<bool?> earlyNotificationsEnabled = const Value.absent(),
    Value<String?> notifyWindow = const Value.absent(),
    Value<String?> seeWithin = const Value.absent(),
  }) => Role._(
    super.copyWith(
      updatedAt: updatedAt,
      pending: pending,
      id: id,
      createdAt: createdAt,
      archivedAt: archivedAt,
      createdBy: createdBy,
      name: name,
      color: color,
      order: order,
      earlyNotificationsEnabled: earlyNotificationsEnabled,
      notifyWindow: notifyWindow,
      seeWithin: seeWithin,
    ),
  );

  Future<void> save() async {
    await Store.get.save(table, toCompanion(false), RolesBase());
  }
}
