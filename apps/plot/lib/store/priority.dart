part of 'store.dart';

typedef PriorityId = Uuid;

@DataClassName('PriorityRow')
class Priorities extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  TextColumn get title => text()();
  // Nullable so a future API that stops sending `path` to path-independent
  // (apiVersion >= 5) clients can't crash `PriorityRow.fromJson`. The client
  // no longer reads `path`; the server still synthesizes it on save during the
  // expand phase. PathConverter still maps the value when present.
  TextColumn get path => text().nullable().map(const PathConverter())();
  BlobColumn get createdBy => blob().map(const UuidConverter())();
  RealColumn get topOrder => real().nullable().map(const OrderConverter())();
  RealColumn get order => real()
      .map(const OrderConverter())
      .clientDefault(
        () =>
            DateTime.now().millisecondsSinceEpoch.toDouble() +
            Random().nextDouble(),
      )();
  IntColumn get pomodoro => integer()
      .nullable()
      .withDefault(const Constant(25 * 60))
      .map(const DurationConverter())();
  IntColumn get color =>
      integer().nullable().map(const ThemeColorConverter())();

  /// The focus's own icon: a curated key string (see `PlotIcon.focusIcons`),
  /// resolved to a glyph in the widget layer via `PlotIcon.focusIcon`. Null
  /// renders the default focus icon.
  TextColumn get icon => text().nullable()();

  /// Human-readable description of what belongs in this focus. Used by the
  /// classifier to match threads to the focus. Null for focuses created before
  /// this field was introduced.
  TextColumn get description => text().nullable()();
  TextColumn get key => text().nullable()();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
  BoolColumn get unread => boolean().withDefault(const Constant(false))();
  TextColumn get role => text().withDefault(const Constant('member'))();
  TextColumn get attentionWindow => text().nullable()();
  TextColumn get seeWithin => text().nullable()();
  BoolColumn get attentionWindowSet =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get seeWithinSet => boolean().withDefault(const Constant(false))();

  /// Master toggle for the "Early notifications" mechanism. When false,
  /// notifications fire only at the placed block-start.
  BoolColumn get earlyNotificationsEnabled => boolean().nullable()();

  /// Active hours during which early notifications may fire. JSON-encoded
  /// `List<AttentionWindow>`.
  TextColumn get notifyWindow => text().nullable()();

  /// `*_set` direct-override flags. True when the user has set the value on
  /// this priority itself (vs. inheriting from an ancestor).
  BoolColumn get earlyNotificationsEnabledSet =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get notifyWindowSet =>
      boolean().withDefault(const Constant(false))();

  /// Sparse per-priority configuration. Not user-editable. Stored as a JSON
  /// string. See `PriorityConfig` for recognized keys.
  TextColumn get config => text().nullable()();

  /// The high-water mark for notifications in this focus. Updated by the
  /// server when sending summaries, and by the client when opening the focus.
  DateTimeColumn get notificationClearedAt => dateTime().nullable()();

  /// The role ([Roles]) this focus belongs to. Nullable for focuses synced
  /// before the role model; the server backfills every focus, so it is
  /// effectively always set once a fresh sync has run.
  BlobColumn get roleId => blob().nullable().map(const UuidConverter())();

  /// Marks the role's auto-managed Inbox focus (server-managed; the client
  /// never sets it). The classifier's per-role catch-all.
  BoolColumn get isInbox => boolean().withDefault(const Constant(false))();

  /// Marks the user's single global FYI focus (server-managed; the client
  /// never sets it). Low-signal mail; renders just above "Everything".
  BoolColumn get isFyi => boolean().withDefault(const Constant(false))();
}

class PrioritiesBase extends BaseTable {
  PrioritiesBase()
    : super(
        table: 'user_priority',
        syncEndpoint: 'priorities',
        name: "priorities",
        order: 'created_at',
      );

  @override
  Insertable<PriorityRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('global_path');
    json['role'] ??= 'member';
    // Remap old column names (response_window → attention_window)
    if (json.containsKey('response_window') &&
        !json.containsKey('attention_window')) {
      json['attention_window'] = json.remove('response_window');
    }
    if (json.containsKey('response_window_set') &&
        !json.containsKey('attention_window_set')) {
      json['attention_window_set'] = json.remove('response_window_set');
    }
    // JSON-encode jsonb-shaped attention fields from API: server sends them
    // as native JSON, Drift stores them as TEXT.
    for (final key in const [
      'attention_window',
      'see_within',
      'notify_window',
    ]) {
      final value = json[key];
      if (value != null && value is! String) {
        json[key] = jsonEncode(value);
      }
    }
    // Drop legacy `respond_*` keys the server may still send while it
    // catches up to the schema drop. These columns no longer exist on
    // the Drift priorities table; leaving them in `json` would trip
    // `PriorityRow.fromJson`.
    json.remove('respond_schedule_enabled');
    json.remove('respond_window');
    json.remove('respond_within');
    json.remove('respond_schedule_enabled_set');
    json.remove('respond_window_set');
    json.remove('respond_within_set');
    // Ensure order is never null — the server COALESCE should prevent this,
    // but a null here causes a native SIGSEGV at sqlite3_bind_double
    json['order'] ??= DateTime.parse(
      json['created_at'] as String,
    ).millisecondsSinceEpoch.toDouble();
    json.remove('inherit_members');
    // config is a JSONB object on the server; Drift stores it as a JSON string.
    if (json['config'] != null) {
      json['config'] = json['config'] is String
          ? json['config']
          : jsonEncode(json['config']);
    }
    // Focuses are team-agnostic and no longer carry per-focus default sharing.
    // Drop these keys in case a server still in mid-deploy emits them; leaving
    // them in `json` would trip `PriorityRow.fromJson`.
    json.remove('team_id');
    json.remove('default_contacts');
    json.remove('default_groups');
    json.remove('default_invite_emails');

    return PriorityRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('unread');
    json.remove('role');
    // Per-priority response-time settings are written via
    // /sync/priority-attention, not via the priorities upsert. Strip them
    // from the generic push body so the upsert never clears them server-side.
    json.remove('attention_window');
    json.remove('see_within');
    json.remove('attention_window_set');
    json.remove('see_within_set');
    json.remove('respond_schedule_enabled');
    json.remove('respond_window');
    json.remove('respond_within');
    json.remove('early_notifications_enabled');
    json.remove('notify_window');
    json.remove('respond_schedule_enabled_set');
    json.remove('respond_window_set');
    json.remove('respond_within_set');
    json.remove('early_notifications_enabled_set');
    json.remove('notify_window_set');
    // config is read-only from the client's perspective.
    json.remove('config');
    // is_inbox is server-managed (set when a role's Inbox focus is
    // auto-created); the client never writes it. role_id is intentionally
    // kept in the body so a modal-driven role change persists and fires the
    // server's role-propagation triggers.
    json.remove('is_inbox');
    json.remove('is_fyi');
    return json;
  }
}

/// Typed view onto the sparse [Priorities.config] JSON blob.
class PriorityConfig {
  const PriorityConfig({this.topic, this.view});

  static const empty = PriorityConfig();

  static PriorityConfig parse(String? raw) {
    if (raw == null || raw.isEmpty) return empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return empty;
      final map = decoded.cast<String, dynamic>();
      return PriorityConfig(
        topic: map['topic'] is String ? map['topic'] as String : null,
        view: map['view'] is String ? map['view'] as String : null,
      );
    } catch (_) {
      return empty;
    }
  }

  /// Topic to stamp on new threads created in this priority.
  final String? topic;

  /// View override. 'activity' hides the agenda tab on the priority page.
  final String? view;

  bool get viewIsActivity => view == 'activity';
}

enum PriorityOrder { sorted, nested, recent }

class PriorityAncestor {
  static List<PriorityAncestor> fromStore(PriorityAncestryData row) {
    // Parse raw arrays from JSON
    final rawTitles = jsonDecode(row.titles) as List;
    final rawIds = jsonDecode(row.ancestors) as List;
    final rawColors = jsonDecode(row.colors) as List;
    // Filter out NULL entries (from LEFT JOIN when ancestor doesn't exist)
    final ids = <Uuid>[];
    final titles = <String>[];
    final colors = <int?>[];

    for (int i = 0; i < rawTitles.length; i++) {
      if (rawTitles[i] != null) {
        titles.add(rawTitles[i] as String);
        ids.add(Uuid.fromString(rawIds[i] as String));
        colors.add(rawColors[i] as int?);
      }
    }

    // Compute display colors with inheritance
    int currentColorIndex = ThemeColor.defaultColor().index;
    final displayColors = <int>[];
    for (int i = 0; i < colors.length; i++) {
      if (colors[i] != null) {
        currentColorIndex = colors[i]!;
      }
      displayColors.add(currentColorIndex);
    }

    return List.generate(
      ids.length,
      (index) => PriorityAncestor(
        id: ids[index],
        title: titles[index],
        color: displayColors[index],
      ),
    );
  }

  const PriorityAncestor({
    required this.id,
    required this.title,
    required this.color,
  });

  final PriorityId id;
  final String title;

  /// The computed display color index (with inheritance applied).
  /// Root priorities default to 7 (Resolution) when no color is explicitly set.
  final int color;
}

class Priority extends PriorityRow implements Comparable<Priority> {
  static $PrioritiesTable get table => Store.get.priorities;

  static Future<bool> push() => Store.get.push(table, PrioritiesBase());
  static Future<void> pull() async {
    // First pull: fetch all priorities if not already initialized
    await Store.get.pull(table, PrioritiesBase(), initial: true);
    // Subsequent pulls: fetch changes since last pull
    await Store.get.pull(table, PrioritiesBase());
  }

  static Future<List<Priority>> get({
    PriorityId? id,
    Path? path,
    int? depth,
    bool? archived = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) async {
    // Trigger archived sync if needed
    if (archived == true) {
      await Store.get.pullArchived(table, PrioritiesBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      await Store.get.pullArchived(table, PrioritiesBase());
    }

    final priorities = await _get(
      id: id,
      path: path,
      depth: depth,
      archived: archived,
      order: order,
      search: search,
      self: self,
    ).get();

    // Compute active/unread status for all priorities
    return _enrichWithStatus(priorities);
  }

  /// Live snapshot of every priority (archived + active, sorted), kept fresh
  /// by [_rawAllWatch]. Serves [getRaw]'s `archived: null` form, which
  /// Thread._mapResultsToThreads issues on every feed/agenda emission (~15×
  /// per focus switch); re-querying it each time piled onto the single SQLite
  /// connection and starved the activity feed.
  static List<Priority>? _rawAllSnapshot;
  static StreamSubscription<List<Priority>>? _rawAllWatch;

  /// Drops the cached all-priorities snapshot and its keep-fresh watch. Call
  /// on sign-out / store reset (mirrors [Actor.clearCache]).
  static void clearCache() {
    _rawAllWatch?.cancel();
    _rawAllWatch = null;
    _rawAllSnapshot = null;
  }

  /// Lightweight priority lookup that skips the `pullArchived` network sync
  /// and `_enrichWithStatus` (two extra SQL queries that compute
  /// active/unread flags). Use this on hot read paths that only need
  /// priority identity / path / display fields, not the unread/active dot
  /// state. Callers that render the priority list itself should keep using
  /// [get].
  ///
  /// The `archived: null` (all priorities), sorted form — issued on every
  /// feed/agenda emission — is served from [_rawAllSnapshot], a live snapshot
  /// kept current by a single watch, so the many concurrent callers during a
  /// focus switch don't each re-scan the priorities table.
  static Future<List<Priority>> getRaw({
    bool? archived = false,
    PriorityOrder order = PriorityOrder.sorted,
  }) async {
    final useSnapshot = archived == null && order == PriorityOrder.sorted;
    if (useSnapshot) {
      final snap = _rawAllSnapshot;
      if (snap != null) return snap;
      // First access: start the keep-fresh watch. Its emissions (initial +
      // every later priority write, local or remote) update the snapshot, so
      // it never goes stale. Use `_get(...).watch()` directly (not the public
      // [watch]) to keep getRaw's no-network contract. Fall through to a
      // direct load so the first caller gets an immediate result instead of
      // waiting on the watch's first async emission.
      _rawAllWatch ??= _get(archived: null, order: PriorityOrder.sorted)
          .watch()
          .listen((rows) => _rawAllSnapshot = rows);
    }
    final result = await _get(archived: archived, order: order).get();
    if (useSnapshot && _rawAllSnapshot == null) _rawAllSnapshot = result;
    return result;
  }

  /// Raw (no-enrichment) live watch of priorities. Unlike [watch] this skips
  /// `pullArchived` and — crucially — the active/unread/non-empty status
  /// streams, each of which scans the threads table and re-fires on every
  /// thread write. Use for consumers that only need identity / path / display
  /// fields kept live (e.g. an id→Priority lookup map); the sidebar list,
  /// which renders the bold/unread dot state, must keep using [watch].
  static Stream<List<Priority>> watchRaw({
    bool? archived = false,
    PriorityOrder order = PriorityOrder.sorted,
  }) {
    if (!Injector.appInstance.exists<Store>()) {
      return Stream.value([]);
    }
    return _get(archived: archived, order: order).watch();
  }

  static Stream<List<Priority>> watch({
    PriorityId? id,
    Path? path,
    int? depth,
    bool? archived = false,
    String? search,
    bool self = true,
    PriorityOrder order = PriorityOrder.sorted,
  }) {
    // Defensive check: Return empty stream if Store is not available (user signing out)
    if (!Injector.appInstance.exists<Store>()) {
      return Stream.value([]);
    }

    // Trigger archived sync if needed
    if (archived == true) {
      Store.get.pullArchived(table, PrioritiesBase());
    } else if (archived == null) {
      // Fetch both archived and non-archived
      Store.get.pullArchived(table, PrioritiesBase());
    }

    // Watch priorities table
    final prioritiesStream = _get(
      id: id,
      path: path,
      depth: depth,
      archived: archived,
      order: order,
      search: search,
      self: self,
    ).watch();

    // Watch active, unread, and non-empty priority IDs
    final activePriorityIdsStream = _watchActivePriorityIds();
    final unreadPriorityIdsStream = _watchUnreadPriorityIds();
    final nonEmptyPriorityIdsStream = _watchNonEmptyPriorityIds();

    // Combine all four streams
    return Rx.combineLatest4(
          prioritiesStream,
          activePriorityIdsStream,
          unreadPriorityIdsStream,
          nonEmptyPriorityIdsStream,
          (priorities, activeIds, unreadIds, nonEmptyIds) =>
              (priorities, activeIds, unreadIds, nonEmptyIds),
        )
        .map((tuple) {
          final priorities = tuple.$1;
          final activeIds = tuple.$2;
          final unreadIds = tuple.$3;
          final nonEmptyIds = tuple.$4;

          return priorities.map((p) {
            return Priority.fromStore(
              p,
              parent: p.parent,
              children: p.children,
              draft: p.draft,
              ancestors: p._ancestors,
              minAncestorTopOrder: p.minAncestorTopOrder,
              active: activeIds.contains(p.id),
              unreadComputed: unreadIds.contains(p.id),
              hasThreads: nonEmptyIds.contains(p.id),
              displayColor: p.displayColor,
            );
          }).toList();
        })
        .debounceTime(const Duration(milliseconds: 100))
        .distinct()
        .transform(
          ExpiringStreamTransformer((priorities) {
            // Re-evaluate every minute on the minute for time-based active status.
            // Uses [Time.now] so expiry stays consistent with the transformer's
            // own `Time.now()`-based timer math under frozen time (otherwise the
            // computed wait could be years long and the stream would stop
            // re-evaluating).
            final now = Time.now();
            final expiry = now.add(
              Duration(
                seconds: 60 - now.second,
                milliseconds: -now.millisecond,
              ),
            );
            return ExpiringResult(value: priorities, expiry: expiry);
          }),
        );
  }

  static Future<Priority> getOne(
    PriorityId id, {
    int? depth = 0,
    bool ancestors = true,
  }) {
    return _get(
      id: id,
      depth: depth,
      archived: null,
      ancestors: ancestors,
      order: PriorityOrder.nested,
    ).get().then((priorities) {
      final nested = asNested(priorities, id: id);
      if (nested.isEmpty) {
        throw StateError('Priority not found: $id');
      }
      return nested.first;
    });
  }

  static Stream<Priority> watchOne(
    PriorityId id, {
    int? depth = 0,
    bool ancestors = true,
  }) {
    return _get(
          id: id,
          depth: depth,
          archived: null,
          ancestors: ancestors,
          order: PriorityOrder.nested,
        )
        .watch()
        .map((priorities) => asNested(priorities, id: id))
        .where((nested) => nested.isNotEmpty)
        .map((nested) => nested.first);
  }

  static Future<bool> hasDefault() async {
    return (await _default().getSingleOrNull()) != null;
  }

  /// True when the user has any non-archived focus beyond the two that
  /// `activate_invited_user` auto-seeds at signup — the root ("Everything")
  /// and the global role-less "FYI" focus. Used as a second-device signal
  /// that the user has already used Plot, so onboarding can be skipped.
  ///
  /// The FYI focus is a *non-root* priority (`is_fyi = true`), so it MUST be
  /// excluded here: counting it makes this fire for every brand-new user and
  /// silently suppresses onboarding (the user keeps the seeded 'Personal'
  /// role they never chose). See `apps/plot/lib/state/onboarding.dart`.
  static Future<bool> hasNonRoot() async {
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            t.root.equals(false) &
            t.isFyi.equals(false),
      )
      ..limit(1);
    return (await query.getSingleOrNull()) != null;
  }

  static Future<Priority> getDefault() async {
    return (await _default().getSingleOrNull())!;
  }

  static Stream<Priority> watchDefault() {
    return _default().watchSingleOrNull().map((p) => p!);
  }

  static Future<List<Priority>> getRoot({int? depth, bool? archived = false}) =>
      get(
        depth: depth,
        archived: archived,
        order: PriorityOrder.nested,
      ).then((priorities) => asNested(priorities));

  static Stream<List<Priority>> watchRoot({
    int? depth,
    bool? archived = false,
  }) => watch(
    depth: depth,
    archived: archived,
    order: PriorityOrder.nested,
  ).map((priorities) => asNested(priorities));

  /// Enriches a list of priorities with computed active/unread status.
  static Future<List<Priority>> _enrichWithStatus(
    List<Priority> priorities,
  ) async {
    if (priorities.isEmpty) return priorities;
    // Sign-out can race with in-flight watch streams; skip enrichment rather
    // than crash on Base.userId when _userId has been cleared.
    if (!Base.signedIn) return priorities;

    // Get all priority IDs
    final priorityIds = priorities.map((p) => p.id).toList();

    // Compute which priorities have active/unread status
    final activeIds = await _getActivePriorityIds(priorityIds);
    final unreadIds = await _getUnreadPriorityIds(priorityIds);
    final nonEmptyIds = await _getNonEmptyPriorityIds(priorityIds);

    // Create new Priority objects with computed status
    return priorities.map((p) {
      return Priority.fromStore(
        p,
        parent: p.parent,
        children: p.children,
        draft: p.draft,
        ancestors: p._ancestors,
        minAncestorTopOrder: p.minAncestorTopOrder,
        active: activeIds.contains(p.id),
        unreadComputed: unreadIds.contains(p.id),
        hasThreads: nonEmptyIds.contains(p.id),
        displayColor: p.displayColor,
      );
    }).toList();
  }

  /// Efficiently gets which priority IDs from the given list have active threads.
  static Future<Set<PriorityId>> _getActivePriorityIds(
    List<PriorityId> ids,
  ) async {
    if (ids.isEmpty) return {};

    // Same race as `_watchActivePriorityIds` — callers can land here mid
    // sign-out, after `Base.userId` has been nulled. Return an empty set
    // instead of crashing the page that triggered the lookup.
    final userId = Base.userIdOrNull;
    if (userId == null) return {};

    final now = Time.now();
    final today = Date.today().toString();
    final idBytes = ids.map((id) => id.toBytes()).toList();

    final a = Store.get.threads;

    // Query 1: Shared (thread-owned) schedules with time filter.
    final s = Store.get.schedules;
    final sharedQuery = Store.get.selectOnly(a)..addColumns([a.priorityId]);
    sharedQuery.join([
      innerJoin(s, s.threadId.equalsExp(a.id) & s.linkId.isNull()),
    ]);
    sharedQuery.where(
      a.priorityId.isIn(idBytes) &
          a.archivedAt.isNull() &
          a.draft.equals(false) &
          ((s.startOn.isSmallerOrEqualValue(today) & s.startAt.isNull()) |
              (s.startAt.isSmallerOrEqualValue(now) &
                  (s.endAt.isNull() | s.endAt.isBiggerOrEqualValue(now)))),
    );

    // Query 2: Per-user state on the thread row — an active to-do scheduled
    // in the past or for today (mirrors `_watchActivePriorityIds`). A
    // future-dated to-do is excluded; an active to-do with no explicit date
    // counts as "now".
    final userQuery = Store.get.selectOnly(a)..addColumns([a.priorityId]);
    userQuery.where(
      a.priorityId.isIn(idBytes) &
          a.archivedAt.isNull() &
          a.draft.equals(false) &
          a.active.equals(true) &
          (a.stateAt.isSmallerOrEqualValue(now) |
              (a.stateAt.isNull() &
                  (a.stateOn.isNull() |
                      a.stateOn.isSmallerOrEqualValue(today)))),
    );

    final sharedResults = await sharedQuery.get();
    final userResults = await userQuery.get();
    return {
      ...sharedResults.map((row) => Uuid.fromBytes(row.read(a.priorityId)!)),
      ...userResults.map((row) => Uuid.fromBytes(row.read(a.priorityId)!)),
    };
  }

  /// Efficiently gets which priority IDs from the given list have unread threads.
  static Future<Set<PriorityId>> _getUnreadPriorityIds(
    List<PriorityId> ids,
  ) async {
    if (ids.isEmpty) return {};

    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);

    // Convert PriorityId (Uuid) to Uint8List for isIn query
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.priorityId.isIn(idBytes) &
          a.unread.equals(true) &
          a.readAt.isNull() &
          a.archivedAt.isNull() &
          a.draft.equals(false),
    );

    final results = await query.get();
    return results
        .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
        .toSet();
  }

  /// Watches which priorities have unread threads.
  /// Returns a stream of priority IDs that have unread items.
  static Stream<Set<PriorityId>> _watchUnreadPriorityIds() {
    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);

    query.where(
      a.unread.equals(true) &
          a.readAt.isNull() &
          a.archivedAt.isNull() &
          a.draft.equals(false),
    );

    return query
        .watch()
        .map(
          (results) => results
              .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
              .toSet(),
        )
        .distinct();
  }

  /// Efficiently gets which of the given priority IDs have at least one
  /// non-archived, non-draft thread filed directly under them.
  static Future<Set<PriorityId>> _getNonEmptyPriorityIds(
    List<PriorityId> ids,
  ) async {
    if (ids.isEmpty) return {};

    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);
    final idBytes = ids.map((id) => id.toBytes()).toList();

    query.where(
      a.priorityId.isIn(idBytes) &
          a.archivedAt.isNull() &
          a.draft.equals(false),
    );

    final results = await query.get();
    return results
        .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
        .toSet();
  }

  /// Watches which priorities have at least one non-archived, non-draft thread.
  static Stream<Set<PriorityId>> _watchNonEmptyPriorityIds() {
    final a = Store.get.threads;
    final query = Store.get.selectOnly(a)..addColumns([a.priorityId]);

    query.where(a.archivedAt.isNull() & a.draft.equals(false));

    return query
        .watch()
        .map(
          (results) => results
              .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
              .toSet(),
        )
        .distinct();
  }

  /// Whether the focus identified by [id] currently has at least one
  /// non-archived, non-draft thread filed directly under it. Used to resolve
  /// the Archive-vs-"Merge into…" label for focuses loaded without
  /// `_enrichWithStatus`.
  static Future<bool> hasThreadsFor(PriorityId id) async {
    final ids = await _getNonEmptyPriorityIds([id]);
    return ids.contains(id);
  }

  /// Watches which priorities have active threads.
  /// Returns a stream of priority IDs that have active tasks.
  /// Uses two separate queries to avoid column collision when aliasing the same table.
  /// Shared schedule time filtering is done in-memory to allow reactive updates.
  static Stream<Set<PriorityId>> _watchActivePriorityIds() {
    // PrioritiesBloc.start() is invoked from the UserReady listener, which can
    // race with a forced sign-out: the bloc-start await may resume after
    // `_forceSignOut` has already nulled `_userId`. Without this guard, the
    // user-schedules query below dereferences `Base.userId!` and crashes the
    // post-auth setup before the UserSignedOut listener gets a chance to
    // stop the bloc cleanly.
    final userId = Base.userIdOrNull;
    if (userId == null) {
      return Stream<Set<PriorityId>>.value(const <PriorityId>{});
    }

    final a = Store.get.threads;

    // Stream 1: Shared (thread-owned) schedules — time filtered in-memory.
    final s = Store.get.schedules;
    final sharedQuery = Store.get.selectOnly(a)
      ..addColumns([a.priorityId, s.startAt, s.startOn, s.endAt, s.endOn]);
    sharedQuery.join([
      innerJoin(s, s.threadId.equalsExp(a.id) & s.linkId.isNull()),
    ]);
    sharedQuery.where(a.archivedAt.isNull() & a.draft.equals(false));

    final sharedStream = sharedQuery.watch().map((results) {
      final now = Time.now();
      final today = Date.today().toString();
      return results
          .where((row) {
            final startAt = row.read(s.startAt);
            final startOn = row.read(s.startOn);
            final endAt = row.read(s.endAt);
            if (startOn != null && startAt == null) {
              final endOn = row.read(s.endOn);
              final end = endOn ?? startOn;
              return startOn.compareTo(today) <= 0 && end.compareTo(today) >= 0;
            }
            if (startAt != null) {
              final started =
                  startAt.isBefore(now) || startAt.isAtSameMomentAs(now);
              final notEnded =
                  endAt == null ||
                  endAt.isAfter(now) ||
                  endAt.isAtSameMomentAs(now);
              return started && notEnded;
            }
            return false;
          })
          .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
          .toSet();
    });

    // Stream 2: Per-user state on the thread row — time filtered
    // in-memory. (userId is implicit since thread_state is per-user.)
    final userQuery = Store.get.selectOnly(a)
      ..addColumns([a.priorityId, a.stateAt, a.stateOn]);
    userQuery.where(
      a.archivedAt.isNull() & a.draft.equals(false) & a.active.equals(true),
    );

    final userStream = userQuery.watch().map((results) {
      final now = Time.now();
      final today = Date.today().toString();
      return results
          .where((row) {
            // A focus is bold when it has an active to-do scheduled in the
            // past or for today. A timed/dated to-do counts only once its
            // date arrives; a future one does not. An active to-do with no
            // explicit date counts as "now" (the common case — marking a
            // thread active without picking a day).
            final startAt = row.read(a.stateAt);
            final startOn = row.read(a.stateOn);
            if (startAt != null) {
              return startAt.isBefore(now) || startAt.isAtSameMomentAs(now);
            }
            if (startOn != null) {
              return startOn.compareTo(today) <= 0;
            }
            return true;
          })
          .map((row) => Uuid.fromBytes(row.read(a.priorityId)!))
          .toSet();
    });

    // Combine both streams
    return Rx.combineLatest2(sharedStream, userStream, (shared, user) {
      return {...shared, ...user};
    }).distinct();
  }

  static MultiSelectable<Priority> _get({
    /* Selectors */
    PriorityId? id,
    Path? path,

    /* Filters */
    int? depth,
    bool ancestors = false,
    bool self = true,
    bool? archived = false,
    String? search,

    /* Sorting */
    PriorityOrder order = PriorityOrder.sorted,

    /* Augmentation */
    bool ancestry = true,
  }) {
    // pullPriorityPath(priorityPath);
    final base = Store.get.alias(Store.get.priorities, 'base');
    final startingQuery = Store.get.select(base);
    if (id != null) {
      startingQuery.where((t) => t.id.equalsValue(id));
    }
    if (path != null) {
      startingQuery.where((t) => t.path.equalsValue(path));
    }

    final p = Store.get.alias(Store.get.priorities, 'p');
    // Path-prefix tree predicate (descendants/ancestors via `path LIKE`).
    // Only valid when `base.path` is non-null. A focus created locally has
    // `path == null` until the server sync synthesizes one, so a bare
    // `LIKE base.path || '%'` would evaluate to NULL → zero rows. In that
    // case fall back to a self-join on id (the focus itself, no
    // descendants/ancestors, depth 0 — correct until sync fills in path).
    final pathTreePredicate =
        p.path.likeExp(base.path + Constant('%')) &
        ((ancestors
                ? base.path.likeExp(p.path + Constant('%'))
                : Constant(true)) |
            (p.path.likeExp(base.path + Constant('%')))) &
        (depth == null
            ? Constant(true)
            : CustomExpression<int>("""
  LENGTH(p.path) - LENGTH(REPLACE(p.path, '.', '')) -
  (CASE WHEN base.path IS NULL THEN 0 ELSE LENGTH(base.path) - LENGTH(REPLACE(base.path, '.', '')) END)
  """).isSmallerOrEqualValue(depth));
    var query = startingQuery.join([
      innerJoin(
        p,
        id == null && path == null
            ? base.id.equalsExp(p.id)
            : (base.path.isNull() & base.id.equalsExp(p.id)) |
                  (base.path.isNotNull() & pathTreePredicate),
      ),
    ]);

    if (archived != null) {
      if (archived) {
        // Show only archived priorities
        query.where(p.archivedAt.isNotNull());
      } else {
        // Show only active priorities: not archived AND no archived ancestors
        query.where(p.archivedAt.isNull());

        // Join ancestry to check for archived ancestors
        final paForFilter = Store.get.alias(
          Store.get.priorityAncestry,
          'pa_filter',
        );
        query = query.join([
          leftOuterJoin(paForFilter, paForFilter.priorityId.equalsExp(p.id)),
        ]);
        query.where(
          paForFilter.hasArchivedAncestor.isNull() |
              paForFilter.hasArchivedAncestor.equals(0),
        );
      }
    }

    if (search?.isNotEmpty == true) {
      query.where(p.title.like('%$search%'));
    }
    if (self == false) {
      if (id != null) {
        query.where(p.id.equalsValue(id).not());
      }
      if (path != null) {
        query.where(p.path.equalsValue(path).not());
      }
    }

    switch (order) {
      case PriorityOrder.sorted:
        query.orderBy([OrderingTerm.asc(p.path)]);
        break;
      case PriorityOrder.nested:
        // order by path so parents always precede children
        query.orderBy([OrderingTerm(expression: p.path)]);
        break;
      case PriorityOrder.recent:
        query = query.join([
          leftOuterJoin(
            Store.get.latestPriorities,
            Store.get.latestPriorities.priorityId.equalsExp(p.id),
          ),
        ]);
        query.orderBy([
          OrderingTerm(
            expression: Store.get.latestPriorities.at,
            mode: OrderingMode.desc,
          ),
          OrderingTerm.asc(p.path),
        ]);
        break;
    }

    if (ancestry) {
      final pa = Store.get.alias(Store.get.priorityAncestry, 'pa');
      return query
          .join([leftOuterJoin(pa, pa.priorityId.equalsExp(p.id))])
          .map(
            (row) => Priority.fromStore(
              row.readTable(p),
              ancestry: row.readTableOrNull(pa),
            ),
          );
    }

    return query.map((row) => Priority.fromStore(row.readTable(p)));
  }

  static SingleOrNullSelectable<Priority> _default() {
    return (Store.get.select(table)
          ..where((t) => t.archivedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm(expression: t.root, mode: OrderingMode.desc),
            // If no priority is marked default, fall back to the first one created
            (t) =>
                OrderingTerm(expression: t.createdAt, mode: OrderingMode.asc),
          ])
          ..limit(1))
        .map(Priority.fromStore);
  }

  static Map<Uuid, Priority> asMap(List<Priority> list) {
    final priorities = <Uuid, Priority>{};
    void add(Priority priority) {
      priorities[priority.id] = priority;
      for (var child in priority.children) {
        add(child);
      }
    }

    for (var p in list) {
      add(p);
    }
    return priorities;
  }

  /// Select priorities from a flat list, path-independent.
  ///
  /// In the flat/role model focuses do not nest (the sidebar groups them by
  /// role, not by a path tree), so the historical parent/child linking this
  /// performed is no longer consumed. This now simply filters the list:
  ///   • [id] set → the single matching priority (or empty).
  ///   • otherwise → the root priority(ies) (`root == true`).
  /// Each returned [Priority] keeps the `_ancestors` it was built with (from
  /// the ancestry join in [_get]), so `ancestorsLabel()` is unaffected.
  static List<Priority> asNested(
    List<Priority> priorities, {
    PriorityId? id,
  }) {
    if (id != null) {
      final match = priorities.firstWhereOrNull((p) => p.id == id);
      return match != null ? [match] : [];
    }
    return priorities.where((p) => p.root).toList();
  }

  Priority({
    required this.parent,
    required super.title,
    super.topOrder,
    super.pomodoro = const Duration(minutes: 25),
    super.color,
    this.draft = false,
  }) : children = [],
       _ancestors =
           parent!._ancestors +
           [
             PriorityAncestor(
               id: parent.id,
               title: parent.title,
               color: parent.displayColor.index,
             ),
           ],
       minAncestorTopOrder = null,
       displayColor = color ?? parent.displayColor,
       _activeComputed = null,
       _unreadComputed = null,
       _hasThreadsComputed = null,
       super(
         id: Uuid.generate(),
         createdBy: Base.userId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         // Path is intentionally left null: the client is path-independent;
         // the server's `upsert_priority` synthesizes `path` on save during
         // the expand phase.
         path: null,
         order: Order(DateTime.now().millisecondsSinceEpoch.toDouble()),
         root: false,
         unread: false,
         role: parent.role,
         roleId: parent.roleId,
         isInbox: false,
         isFyi: false,
         attentionWindowSet: false,
         seeWithinSet: false,
         earlyNotificationsEnabledSet: false,
         notifyWindowSet: false,
       ) {
    if (!draft) {
      parent!._addChild(this);
    }
  }

  Priority.fromStore(
    PriorityRow row, {
    this.parent,
    List<Priority>? children,
    PriorityAncestryData? ancestry,
    List<PriorityAncestor>? ancestors,
    Order? minAncestorTopOrder,
    this.draft = false,
    bool? active,
    bool? unreadComputed,
    bool? hasThreads,
    ThemeColor? displayColor,
  }) : children = children ?? [],
       _ancestors =
           ancestors ??
           (ancestry == null
               ? parent == null
                     ? const []
                     : parent._ancestors +
                           [
                             PriorityAncestor(
                               id: parent.id,
                               title: parent.title,
                               color: parent.displayColor.index,
                             ),
                           ]
               : PriorityAncestor.fromStore(ancestry)),
       minAncestorTopOrder =
           minAncestorTopOrder ?? ancestry?.minAncestorTopOrder,
       displayColor =
           displayColor ??
           row.color ??
           _computeDisplayColor(
             ancestry: ancestry,
             parent: parent,
             isRoot: row.root,
           ),
       _activeComputed = active,
       // ignore: prefer_initializing_formals
       _unreadComputed = unreadComputed,
       _hasThreadsComputed = hasThreads,
       super(
         id: row.id,
         createdAt: row.createdAt,
         updatedAt: row.updatedAt,
         pending: row.pending,
         archivedAt: row.archivedAt,
         title: row.title,
         topOrder: row.topOrder,
         order: row.order,
         pomodoro: row.pomodoro,
         color: row.color,
         icon: row.icon,
         description: row.description,
         key: row.key,
         root: row.root,
         path: row.path,
         createdBy: row.createdBy,
         unread: row.unread,
         role: row.role,
         attentionWindow: row.attentionWindow,
         seeWithin: row.seeWithin,
         attentionWindowSet: row.attentionWindowSet,
         seeWithinSet: row.seeWithinSet,
         earlyNotificationsEnabled: row.earlyNotificationsEnabled,
         notifyWindow: row.notifyWindow,
         earlyNotificationsEnabledSet: row.earlyNotificationsEnabledSet,
         notifyWindowSet: row.notifyWindowSet,
         config: row.config,
         notificationClearedAt: row.notificationClearedAt,
         roleId: row.roleId,
         isInbox: row.isInbox,
         isFyi: row.isFyi,
       ) {
    if (!draft) {
      parent?._addChild(this);
    }
  }

  static ThemeColor _computeDisplayColor({
    PriorityAncestryData? ancestry,
    Priority? parent,
    required bool isRoot,
  }) {
    // If we have ancestry data, walk from last (parent) to first (root)
    if (ancestry != null) {
      final colors = (jsonDecode(ancestry.colors) as List)
          .map((e) => e as int?)
          .toList();
      // Walk from parent (last) to root (first)
      for (int i = colors.length - 1; i >= 0; i--) {
        if (colors[i] != null) {
          return ThemeColor(colors[i]!);
        }
      }
    } else if (parent != null) {
      // Use parent's displayColor
      return parent.displayColor;
    }
    return const ThemeColor.defaultColor();
  }

  static const separator = ' › ';

  List<PriorityAncestor> ancestors({
    Priority? context,
    bool includeSelf = false,
  }) {
    final ancestors = [
      ..._ancestors,
      if (includeSelf)
        PriorityAncestor(id: id, title: title, color: displayColor.index),
    ];
    if (context != null) {
      int startIndex = ancestors.indexWhere((a) => a.id == context.id);
      if (startIndex != -1) {
        return ancestors.sublist(startIndex + 1);
      }
    }
    if (ancestors.length > (includeSelf ? 1 : 0)) {
      // Skip "Everything" root priority
      return ancestors.sublist(1);
    }
    return ancestors;
  }

  String? ancestorsLabel({Priority? context}) {
    final ancestors = this.ancestors(context: context);
    if (ancestors.isEmpty) {
      return null;
    }
    return (ancestors
            .map((a) => a.title)
            .toList()
            .expand((p) => [p, separator])
            .toList()
          ..removeLast())
        .join();
  }

  /// Whether this priority matches [search] using word-prefix matching
  /// against its own title and every visible ancestor title. Each
  /// whitespace-separated search token must prefix some word somewhere
  /// in the path — so "per" matches "Personal" and "Personal › Fitness"
  /// but never "Hyper", and "per fit" still matches "Personal › Fitness".
  bool matchesSearch(String search) {
    final query = search.trim().toLowerCase();
    if (query.isEmpty) return true;
    final tokens = query.split(RegExp(r'\s+'));
    final words =
        <String>[title, for (final ancestor in ancestors()) ancestor.title]
            .expand((t) => t.toLowerCase().split(RegExp(r'[\s/]+')))
            .where((w) => w.isNotEmpty)
            .toList();
    return tokens.every((t) => words.any((w) => w.startsWith(t)));
  }

  final Priority? parent;
  PriorityId? get parentId => parent?.id ?? _ancestors.lastOrNull?.id;
  List<Priority> children;
  final List<PriorityAncestor> _ancestors;
  final Order? minAncestorTopOrder;
  final ThemeColor displayColor;

  /// Whether this priority is a draft (not added to parent's children list).
  /// This is an in-memory property only, not persisted to the database.
  final bool draft;

  /// Computed active status from query (true if priority has active threads).
  /// Falls back to false if not computed.
  final bool? _activeComputed;

  /// Computed unread status from query (considers local overrides).
  /// Falls back to row's unread value if not computed.
  final bool? _unreadComputed;

  /// Computed "has threads" status from query: true when the focus has at
  /// least one non-archived, non-draft thread filed directly under it. Falls
  /// back to false when not computed (e.g. loaded without `_enrichWithStatus`).
  final bool? _hasThreadsComputed;

  /// The user-facing name for this priority. The per-user root focus is
  /// stored as "Everything" in the database (the server projects it as
  /// "Inbox" at apiVersion >= 4, but older synced roots still carry the raw
  /// title), yet it is always presented to users as "Inbox". Read this
  /// anywhere a priority name is shown to the user instead of the raw
  /// [title], so the stored "Everything" never leaks into the UI.
  ///
  /// A role's auto-managed Inbox focus ([isInbox]) is always presented as
  /// "Inbox". `root` is also honoured for back-compat during the additive
  /// rollout: a legacy per-user root still labels "Inbox" until the server
  /// has backfilled [isInbox]. (Plan 6 removes `root` entirely.)
  String get displayTitle => (isInbox || root) ? 'Inbox' : title;

  /// Parsed attention window settings (inherited from this priority or ancestors).
  List<AttentionWindow>? get attentionWindows =>
      AttentionWindow.fromJsonString(attentionWindow);

  /// Parsed "see within" time (inherited from this priority or
  /// ancestors). Single window — server collapsed the previous
  /// requests/updates pair into one knob.
  SeeWithinTime? get seeWithinTime => SeeWithinTime.fromJsonString(seeWithin);

  /// Parsed "notify during" windows (inherited).
  List<AttentionWindow>? get notifyWindows =>
      AttentionWindow.fromJsonString(notifyWindow);

  /// Parsed sparse priority config (topic/view behaviours). Not
  /// user-editable; populated from the server.
  PriorityConfig get priorityConfig => PriorityConfig.parse(config);

  /// Returns true if this priority has active threads.
  bool get active => _activeComputed ?? false;

  /// Returns true when this focus has at least one non-archived, non-draft
  /// thread filed directly under it. Drives the Archive-vs-"Merge into…"
  /// choice on the focus menu. Defaults to false when not computed.
  bool get hasThreads => _hasThreadsComputed ?? false;

  /// Returns true if this priority has unread threads (considering local overrides).
  /// Falls back to the row's unread value if not computed.
  @override
  bool get unread => _unreadComputed ?? super.unread;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Priority &&
          super == other &&
          _activeComputed == other._activeComputed &&
          _unreadComputed == other._unreadComputed &&
          _hasThreadsComputed == other._hasThreadsComputed &&
          displayColor == other.displayColor);

  @override
  int get hashCode => Object.hash(
    super.hashCode,
    _activeComputed,
    _unreadComputed,
    _hasThreadsComputed,
    displayColor,
  );

  List<Priority> descendants() {
    List<Priority> result = [];

    // Recursive helper to collect descendants
    void collectDescendants(Priority priority) {
      for (var child in priority.children) {
        result.add(child);
        collectDescendants(child);
      }
    }

    collectDescendants(this);
    result.sort();
    return result;
  }

  Future<void> delete() async {
    await copyWith(archivedAt: Value(DateTime.now())).save();
  }

  @override
  Priority copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    Value<DateTime?> archivedAt = const Value.absent(),
    String? title,
    Value<Path?> path = const Value.absent(),
    Uuid? createdBy,
    Value<Order?> topOrder = const Value.absent(),
    Order? order,
    Value<Duration?> pomodoro = const Value.absent(),
    Value<ThemeColor?> color = const Value.absent(),
    Value<String?> icon = const Value.absent(),
    Value<String?> description = const Value.absent(),
    Value<String?> key = const Value.absent(),
    bool? root,
    Priority? parent,
    Value<int?> pending = const Value.absent(),
    bool? unread,
    String? role,
    Value<String?> attentionWindow = const Value.absent(),
    Value<String?> seeWithin = const Value.absent(),
    bool? attentionWindowSet,
    bool? seeWithinSet,
    Value<bool?> earlyNotificationsEnabled = const Value.absent(),
    Value<String?> notifyWindow = const Value.absent(),
    bool? earlyNotificationsEnabledSet,
    bool? notifyWindowSet,
    Value<String?> config = const Value.absent(),
    bool? draft,
    Value<DateTime?> notificationClearedAt = const Value.absent(),
    Value<Uuid?> roleId = const Value.absent(),
    bool? isInbox,
    bool? isFyi,
  }) {
    final newDraft = draft ?? this.draft;
    final currentParent = parent ?? this.parent;

    // Handle draft transitions
    if (draft != null && draft != this.draft && currentParent != null) {
      if (draft == true && !this.draft) {
        // Transitioning from non-draft to draft: remove from parent's children
        _removeFromParent(currentParent);
      }
      // Transitioning from draft to non-draft is handled by fromStore constructor
    }

    return Priority.fromStore(
      super.copyWith(
        id: id,
        createdBy: createdBy,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: DateTime.now(),
        pending: pending,
        archivedAt: archivedAt,
        title: title ?? this.title,
        path: path,
        topOrder: topOrder,
        order: order,
        pomodoro: pomodoro,
        color: color,
        icon: icon,
        description: description,
        key: key,
        root: root,
        unread: unread,
        role: role,
        attentionWindow: attentionWindow,
        seeWithin: seeWithin,
        attentionWindowSet: attentionWindowSet,
        seeWithinSet: seeWithinSet,
        earlyNotificationsEnabled: earlyNotificationsEnabled,
        notifyWindow: notifyWindow,
        earlyNotificationsEnabledSet: earlyNotificationsEnabledSet,
        notifyWindowSet: notifyWindowSet,
        config: config,
        notificationClearedAt: notificationClearedAt,
        roleId: roleId,
        isInbox: isInbox,
        isFyi: isFyi,
      ),
      parent: currentParent,
      children: children,
      draft: newDraft,
      ancestors: _ancestors,
      minAncestorTopOrder: minAncestorTopOrder,
      active: _activeComputed,
      unreadComputed: _unreadComputed,
      hasThreads: _hasThreadsComputed,
    );
  }

  /// Returns a copy of this priority with the computed [hasThreads] flag set,
  /// preserving every other computed-enrichment field. Used to enrich the
  /// current focus where the owning bloc loads it without `_enrichWithStatus`
  /// (header and command-scope menus).
  Priority withHasThreads(bool value) => Priority.fromStore(
    this,
    parent: parent,
    children: children,
    draft: draft,
    ancestors: _ancestors,
    minAncestorTopOrder: minAncestorTopOrder,
    active: _activeComputed,
    unreadComputed: _unreadComputed,
    hasThreads: value,
  );

  void _removeFromParent(Priority parent) {
    parent.children = parent.children.where((child) => child.id != id).toList();
  }

  void _addChild(Priority child) {
    children = List<Priority>.from(
      children,
    ).replaceSorted(child, (a, b) => a.id == b.id);
  }

  List<Priority> get peers => parent?.children ?? [];

  Future<Priority> save() async {
    if (draft) {
      // If this is a draft, create a non-draft copy and save it
      final nonDraft = copyWith(draft: false);
      await Store.get.save(
        table,
        nonDraft.toCompanion(false),
        PrioritiesBase(),
      );
      return nonDraft;
    }
    // Flat/role model: focuses don't nest or reparent (role membership is set
    // via `role_id`, not a path move), so there is no descendant-path
    // propagation to perform. Save the row as-is.
    await Store.get.save(table, toCompanion(false), PrioritiesBase());
    return this;
  }

  @override
  int compareTo(Priority other) {
    // For peers (same parent), sort by order
    if (parent?.id == other.parent?.id) {
      final orderCompare = order.value.compareTo(other.order.value);
      if (orderCompare != 0) return orderCompare;
    }

    // Fall back to createdAt
    return createdAt.compareTo(other.createdAt);
  }
}

enum PriorityPendingSync {
  /// Full priority data changed
  full(2);

  const PriorityPendingSync(this.value);
  final int value;
}
