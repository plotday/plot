part of 'store.dart';

typedef PriorityId = Uuid;

@DataClassName('PriorityRow')
class Priorities extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  TextColumn get title => text()();
  TextColumn get path => text().map(const PathConverter())();
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
  TextColumn get key => text().nullable()();
  BoolColumn get root => boolean().withDefault(const Constant(false))();
  BoolColumn get unread => boolean().withDefault(const Constant(false))();
  TextColumn get role => text().withDefault(const Constant('member'))();
  Int64Column get teamId => int64().nullable()();
  TextColumn get attentionWindow => text().nullable()();
  TextColumn get seeWithinRequests => text().nullable()();
  TextColumn get seeWithinUpdates => text().nullable()();
  BoolColumn get attentionWindowSet =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get seeWithinRequestsSet =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get seeWithinUpdatesSet =>
      boolean().withDefault(const Constant(false))();

  /// Sparse per-priority configuration. Not user-editable. Stored as a JSON
  /// string. See `PriorityConfig` for recognized keys.
  TextColumn get config => text().nullable()();

  /// Contacts auto-added to any new thread filed under this priority. Stored
  /// as a JSON-encoded list of contact UUIDs. Empty list means no defaults.
  TextColumn get defaultContacts =>
      text().nullable().map(const UuidListConverter())();

  /// Groups auto-added to any new thread filed under this priority. Stored
  /// as a JSON-encoded list of group UUIDs. Empty list means no defaults.
  TextColumn get defaultGroups =>
      text().nullable().map(const UuidListConverter())();

  /// Invite emails auto-added to any new thread filed under this priority.
  /// Stored as a JSON-encoded list of email strings.
  TextColumn get defaultInviteEmails => text().nullable()();
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
    // JSON-encode attention_window and see_within_* from API (JSON objects → strings for Drift text columns)
    if (json['attention_window'] != null) {
      json['attention_window'] = json['attention_window'] is String
          ? json['attention_window']
          : jsonEncode(json['attention_window']);
    }
    if (json['see_within_requests'] != null) {
      json['see_within_requests'] = json['see_within_requests'] is String
          ? json['see_within_requests']
          : jsonEncode(json['see_within_requests']);
    }
    if (json['see_within_updates'] != null) {
      json['see_within_updates'] = json['see_within_updates'] is String
          ? json['see_within_updates']
          : jsonEncode(json['see_within_updates']);
    }
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
    // default_contacts/default_groups/default_invite_emails arrive from the
    // API as either native JSON arrays or, when the pg driver on the worker
    // falls back to text for array types, as strings (`"[]"`, `"{}"`, or
    // `"{uuid1,uuid2}"`). Normalize to a List<dynamic> for the uuid-backed
    // columns (UuidListConverter expects List<dynamic> at the JSON boundary)
    // and to a JSON string for default_invite_emails (plain TextColumn).
    json['default_contacts'] = _normalizeArrayField(json['default_contacts']);
    json['default_groups'] = _normalizeArrayField(json['default_groups']);
    final normalizedEmails = _normalizeArrayField(json['default_invite_emails']);
    json['default_invite_emails'] = normalizedEmails.isEmpty
        ? null
        : jsonEncode(normalizedEmails);

    return PriorityRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('unread');
    json.remove('role');
    json.remove('attention_window');
    json.remove('see_within_requests');
    json.remove('see_within_updates');
    json.remove('attention_window_set');
    json.remove('see_within_requests_set');
    json.remove('see_within_updates_set');
    // config is read-only from the client's perspective.
    json.remove('config');
    // default_contacts / default_groups / default_invite_emails are stored
    // locally as JSON strings; the server expects native Postgres arrays.
    final defaultContacts = json['default_contacts'];
    if (defaultContacts is String) {
      json['default_contacts'] = defaultContacts.isEmpty
          ? <String>[]
          : jsonDecode(defaultContacts) as List<dynamic>;
    } else {
      json['default_contacts'] ??= <String>[];
    }
    final defaultGroups = json['default_groups'];
    if (defaultGroups is String) {
      json['default_groups'] = defaultGroups.isEmpty
          ? <String>[]
          : jsonDecode(defaultGroups) as List<dynamic>;
    } else {
      json['default_groups'] ??= <String>[];
    }
    final defaultInviteEmails = json['default_invite_emails'];
    if (defaultInviteEmails is String) {
      json['default_invite_emails'] = defaultInviteEmails.isEmpty
          ? <String>[]
          : jsonDecode(defaultInviteEmails) as List<dynamic>;
    } else {
      json['default_invite_emails'] ??= <String>[];
    }
    return json;
  }
}

/// Normalize an array-typed field coming from the API to a `List<dynamic>`.
/// Handles native JSON arrays, JSON array strings (`"[]"`, `"[\"uuid\"]"`),
/// and PostgreSQL text array literals (`"{}"`, `"{uuid1,uuid2}"`). Returns
/// an empty list for null or unparseable input.
List<dynamic> _normalizeArrayField(dynamic raw) {
  if (raw == null) return const [];
  if (raw is List) return raw;
  if (raw is String) {
    if (raw.isEmpty || raw == '{}' || raw == '[]') return const [];
    if (raw.startsWith('[')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
      } catch (_) {}
    }
    if (raw.startsWith('{') && raw.endsWith('}')) {
      final inner = raw.substring(1, raw.length - 1);
      if (inner.isEmpty) return const [];
      return inner
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map<dynamic>((s) {
            // PG text arrays wrap quoted strings (e.g. {"a,b","c"}). Strip
            // surrounding double quotes and unescape basic sequences.
            if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
              return s
                  .substring(1, s.length - 1)
                  .replaceAll(r'\"', '"')
                  .replaceAll(r'\\', r'\');
            }
            return s;
          })
          .toList();
    }
  }
  return const [];
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

  /// Lightweight priority lookup that skips the `pullArchived` network sync
  /// and `_enrichWithStatus` (two extra SQL queries that compute
  /// active/unread flags). Use this on hot read paths that only need
  /// priority identity / path / display fields, not the unread/active dot
  /// state. Callers that render the priority list itself should keep using
  /// [get].
  static Future<List<Priority>> getRaw({
    bool? archived = false,
    PriorityOrder order = PriorityOrder.sorted,
  }) {
    return _get(archived: archived, order: order).get();
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

    // Watch active and unread priority IDs
    final activePriorityIdsStream = _watchActivePriorityIds();
    final unreadPriorityIdsStream = _watchUnreadPriorityIds();

    // Combine all three streams
    return Rx.combineLatest3(
          prioritiesStream,
          activePriorityIdsStream,
          unreadPriorityIdsStream,
          (priorities, activeIds, unreadIds) =>
              (priorities, activeIds, unreadIds),
        )
        .map((tuple) {
          final priorities = tuple.$1;
          final activeIds = tuple.$2;
          final unreadIds = tuple.$3;

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

  /// True when the user has any non-archived priority beyond what
  /// `activate_invited_user` auto-seeds at signup (the root and the
  /// `@plot.app` "Using Plot" priority). Used as a second-device signal
  /// that the user has already used Plot, so onboarding can be skipped.
  static Future<bool> hasNonRoot() async {
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            t.root.equals(false) &
            (t.key.isNull() | t.key.equals('@plot.app').not()),
      )
      ..limit(1);
    return (await query.getSingleOrNull()) != null;
  }

  /// Returns the count of other non-archived top-level priorities that share
  /// the same [teamId] as the given priority (excluding [excludeId]). A
  /// top-level priority is one whose path has exactly one dot (depth == 2),
  /// meaning its parent is the root priority. Used to decide whether archiving
  /// a priority should trigger a "leave team" flow.
  static Future<int> countOtherTopLevelTeamPriorities({
    required BigInt teamId,
    required Uuid excludeId,
  }) async {
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            t.root.equals(false) &
            t.teamId.equals(teamId) &
            t.id.equalsValue(excludeId).not() &
            // depth == 2: path has exactly one dot (e.g. "abc1.xyz2")
            t.path.like('%.%') &
            t.path.like('%.%.%').not(),
      );
    return (await query.get()).length;
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

    // Query 1: Shared schedules (userId IS NULL) with time filter
    final s = Store.get.schedules;
    final sharedQuery = Store.get.selectOnly(a)..addColumns([a.priorityId]);
    sharedQuery.join([
      innerJoin(s, s.threadId.equalsExp(a.id) & s.userId.isNull()),
    ]);
    sharedQuery.where(
      a.priorityId.isIn(idBytes) &
          a.archivedAt.isNull() &
          a.draft.equals(false) &
          ((s.startOn.isSmallerOrEqualValue(today) & s.startAt.isNull()) |
              (s.startAt.isSmallerOrEqualValue(now) &
                  (s.endAt.isNull() | s.endAt.isBiggerOrEqualValue(now)))),
    );

    // Query 2: User schedules (userId = current user) with time filter
    final us = Store.get.schedules;
    final userQuery = Store.get.selectOnly(a)..addColumns([a.priorityId]);
    userQuery.join([
      innerJoin(
        us,
        us.threadId.equalsExp(a.id) &
            us.userId.equalsValue(userId) &
            us.occurrence.isNull() &
            us.archivedAt.isNull(),
      ),
    ]);
    userQuery.where(
      a.priorityId.isIn(idBytes) &
          a.archivedAt.isNull() &
          a.draft.equals(false) &
          ((us.startOn.isSmallerOrEqualValue(today) & us.startAt.isNull()) |
              (us.startAt.isSmallerOrEqualValue(now))),
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

    // Stream 1: Shared schedules (userId IS NULL) — time filtered in-memory
    final s = Store.get.schedules;
    final sharedQuery = Store.get.selectOnly(a)
      ..addColumns([a.priorityId, s.startAt, s.startOn, s.endAt, s.endOn]);
    sharedQuery.join([
      innerJoin(s, s.threadId.equalsExp(a.id) & s.userId.isNull()),
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

    // Stream 2: User schedules (userId = current user) — time filtered in-memory
    final us = Store.get.schedules;
    final userQuery = Store.get.selectOnly(a)
      ..addColumns([a.priorityId, us.startAt, us.startOn]);
    userQuery.join([
      innerJoin(
        us,
        us.threadId.equalsExp(a.id) &
            us.userId.equalsValue(userId) &
            us.occurrence.isNull() &
            us.archivedAt.isNull(),
      ),
    ]);
    userQuery.where(a.archivedAt.isNull() & a.draft.equals(false));

    final userStream = userQuery.watch().map((results) {
      final now = Time.now();
      final today = Date.today().toString();
      return results
          .where((row) {
            final startAt = row.read(us.startAt);
            final startOn = row.read(us.startOn);
            if (startAt != null) {
              return startAt.isBefore(now) || startAt.isAtSameMomentAs(now);
            }
            if (startOn != null) {
              return startOn.compareTo(today) <= 0;
            }
            return false;
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
    var query = startingQuery.join([
      innerJoin(
        p,
        id == null && path == null
            ? base.id.equalsExp(p.id)
            : p.path.likeExp(base.path + Constant('%')) &
                  ((ancestors
                          ? base.path.likeExp(p.path + Constant('%'))
                          : Constant(true)) |
                      (p.path.likeExp(base.path + Constant('%')))) &
                  (depth == null
                      ? Constant(true)
                      : CustomExpression<int>("""
  LENGTH(p.path) - LENGTH(REPLACE(p.path, '.', '')) -
  (CASE WHEN base.path IS NULL THEN 0 ELSE LENGTH(base.path) - LENGTH(REPLACE(base.path, '.', '')) END)
  """).isSmallerOrEqualValue(depth)),
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

  /// Transform a flat list in PriorityOrder.nested order to a list of the top-level items with descendants.
  static List<Priority> asNested(
    List<Priority> priorities, {
    PriorityId? id,
    Path? path,
    bool flat = false,
  }) {
    List<Priority> matches = [];
    List<Priority> stack = [];

    for (var priority in priorities) {
      if (stack.isNotEmpty && !stack.last.path.isParent(priority.path)) {
        stack.removeWhere((c) => !c.path.isParent(priority.path));
      }

      if (stack.isNotEmpty) {
        priority = priority.copyWith(parent: stack.last);
      }

      if ((id == null && path == null && priority.path.isRoot) ||
          priority.path == path ||
          priority.id == id) {
        matches.add(priority);
        stack.clear();
      } else if (flat) {
        matches.add(priority);
      }

      stack.add(priority);
    }

    matches.sort((a, b) => a.path.value.compareTo(b.path.value));
    return matches;
  }

  Priority({
    required this.parent,
    required super.title,
    super.topOrder,
    super.pomodoro = const Duration(minutes: 25),
    super.color,
    super.teamId,
    this.draft = false,
    List<Uuid>? defaultContacts,
    List<Uuid>? defaultGroups,
    List<String>? defaultInviteEmails,
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
       _originalPath = null,
       _activeComputed = null,
       _unreadComputed = null,
       super(
         id: Uuid.generate(),
         createdBy: Base.userId,
         createdAt: DateTime.now(),
         updatedAt: DateTime.now(),
         path: Path.generate(parent: parent.path),
         order: Order(DateTime.now().millisecondsSinceEpoch.toDouble()),
         root: false,
         unread: false,
         role: parent.role,
         attentionWindowSet: false,
         seeWithinRequestsSet: false,
         seeWithinUpdatesSet: false,
         defaultContacts:
             defaultContacts == null || defaultContacts.isEmpty
                 ? null
                 : defaultContacts,
         defaultGroups:
             defaultGroups == null || defaultGroups.isEmpty
                 ? null
                 : defaultGroups,
         defaultInviteEmails:
             defaultInviteEmails == null || defaultInviteEmails.isEmpty
                 ? null
                 : jsonEncode(defaultInviteEmails),
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
    Path? originalPath,
    bool? active,
    bool? unreadComputed,
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
       _originalPath = originalPath ?? row.path,
       displayColor =
           displayColor ??
           row.color ??
           _computeDisplayColor(
             ancestry: ancestry,
             parent: parent,
             isRoot: row.root,
           ),
       _activeComputed = active,
       _unreadComputed = unreadComputed,
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
         key: row.key,
         root: row.root,
         path: row.path,
         createdBy: row.createdBy,
         unread: row.unread,
         role: row.role,
         attentionWindow: row.attentionWindow,
         seeWithinRequests: row.seeWithinRequests,
         seeWithinUpdates: row.seeWithinUpdates,
         attentionWindowSet: row.attentionWindowSet,
         seeWithinRequestsSet: row.seeWithinRequestsSet,
         seeWithinUpdatesSet: row.seeWithinUpdatesSet,
         config: row.config,
         defaultContacts: row.defaultContacts,
         defaultGroups: row.defaultGroups,
         defaultInviteEmails: row.defaultInviteEmails,
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
    final words = <String>[
      title,
      for (final ancestor in ancestors()) ancestor.title,
    ]
        .expand((t) => t.toLowerCase().split(RegExp(r'[\s/]+')))
        .where((w) => w.isNotEmpty)
        .toList();
    return tokens.every((t) => words.any((w) => w.startsWith(t)));
  }

  /// Get the effective topOrder for sorting, considering both this priority's
  /// topOrder and the minimum topOrder from its ancestry.
  /// Returns the minimum (earliest) value, as lower Order values sort first.
  Order? get effectiveTopOrder {
    // If both exist, return the minimum (earliest)
    if (topOrder != null && minAncestorTopOrder != null) {
      return topOrder!.value < minAncestorTopOrder!.value
          ? topOrder
          : minAncestorTopOrder;
    }
    // Return whichever one exists, or null if neither exists
    return topOrder ?? minAncestorTopOrder;
  }

  final Priority? parent;
  PriorityId? get parentId => parent?.id ?? _ancestors.lastOrNull?.id;
  List<Priority> children;
  final List<PriorityAncestor> _ancestors;
  final Order? minAncestorTopOrder;
  final ThemeColor displayColor;

  /// The original path from the database, used to detect parent changes.
  /// Null for newly created priorities that haven't been saved yet.
  final Path? _originalPath;

  /// Whether this priority is a draft (not added to parent's children list).
  /// This is an in-memory property only, not persisted to the database.
  final bool draft;

  /// Computed active status from query (true if priority has active threads).
  /// Falls back to false if not computed.
  final bool? _activeComputed;

  /// Computed unread status from query (considers local overrides).
  /// Falls back to row's unread value if not computed.
  final bool? _unreadComputed;


  /// Returns true if this priority has a viewer role (read-only).
  bool get isViewer => role == 'viewer';

  /// Whether the priority should only display its activity feed (no agenda
  /// tab). True for viewer priorities, or when `config.view == 'activity'`.
  bool get isActivityOnly => isViewer || priorityConfig.viewIsActivity;

  /// Whether this is a system priority. Users can rename / recolor / re-parent
  /// these, but cannot archive them, add sub-priorities under them, configure
  /// default sharing on them, or pick them as a parent for another priority.
  bool get isPlot =>
      key == '@plot.app' || key == '@plot.twist-dev' || key == '@plot';

  /// Whether this is the Using Plot priority.
  bool get isPlotApp => key == '@plot.app';

  /// Whether this is the Twist Development priority.
  bool get isTwistDev => key == '@plot.twist-dev';

  /// Parsed attention window settings (inherited from this priority or ancestors).
  List<AttentionWindow>? get attentionWindows =>
      AttentionWindow.fromJsonString(attentionWindow);

  /// Parsed see within requests time (inherited from this priority or ancestors).
  SeeWithinTime? get seeWithinRequestsTime =>
      SeeWithinTime.fromJsonString(seeWithinRequests);

  /// Parsed see within updates time (inherited from this priority or ancestors).
  SeeWithinTime? get seeWithinUpdatesTime =>
      SeeWithinTime.fromJsonString(seeWithinUpdates);

  /// Parsed sparse priority config (topic/view behaviours). Not
  /// user-editable; populated from the server.
  PriorityConfig get priorityConfig => PriorityConfig.parse(config);

  /// Contacts to seed onto any new thread filed under this priority.
  /// Empty when no defaults are configured.
  List<Uuid> get defaultSharedContacts => defaultContacts ?? const [];

  /// Groups to seed onto any new thread filed under this priority.
  /// Empty when no defaults are configured.
  List<Uuid> get defaultSharedGroups => defaultGroups ?? const [];

  /// Invite emails to seed onto any new thread filed under this priority.
  /// Empty when no defaults are configured.
  List<String> get defaultSharedInviteEmails {
    final raw = defaultInviteEmails;
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// Union of `defaultSharedContacts` from this priority and every ancestor
  /// reachable via the `.parent` chain. Preserves insertion order starting
  /// from the current priority, then walking up toward the root.
  List<Uuid> get inheritedDefaultSharedContacts {
    final seen = <Uuid>{};
    final ordered = <Uuid>[];
    for (Priority? p = this; p != null; p = p.parent) {
      for (final id in p.defaultSharedContacts) {
        if (seen.add(id)) ordered.add(id);
      }
    }
    return ordered;
  }

  /// Union of `defaultSharedGroups` from this priority and every ancestor.
  List<Uuid> get inheritedDefaultSharedGroups {
    final seen = <Uuid>{};
    final ordered = <Uuid>[];
    for (Priority? p = this; p != null; p = p.parent) {
      for (final id in p.defaultSharedGroups) {
        if (seen.add(id)) ordered.add(id);
      }
    }
    return ordered;
  }

  /// Union of `defaultSharedInviteEmails` from this priority and every ancestor.
  List<String> get inheritedDefaultSharedInviteEmails {
    final seen = <String>{};
    final ordered = <String>[];
    for (Priority? p = this; p != null; p = p.parent) {
      for (final email in p.defaultSharedInviteEmails) {
        if (seen.add(email)) ordered.add(email);
      }
    }
    return ordered;
  }

  /// Returns true if this priority has active threads.
  bool get active => _activeComputed ?? false;

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
          displayColor == other.displayColor);

  @override
  int get hashCode => Object.hash(
    super.hashCode,
    _activeComputed,
    _unreadComputed,
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
    Path? path,
    Uuid? createdBy,
    Value<Order?> topOrder = const Value.absent(),
    Order? order,
    Value<Duration?> pomodoro = const Value.absent(),
    Value<ThemeColor?> color = const Value.absent(),
    Value<String?> key = const Value.absent(),
    bool? root,
    Priority? parent,
    Value<int?> pending = const Value.absent(),
    bool? unread,
    String? role,
    Value<String?> attentionWindow = const Value.absent(),
    Value<String?> seeWithinRequests = const Value.absent(),
    Value<String?> seeWithinUpdates = const Value.absent(),
    Value<BigInt?> teamId = const Value.absent(),
    bool? attentionWindowSet,
    bool? seeWithinRequestsSet,
    bool? seeWithinUpdatesSet,
    Value<String?> config = const Value.absent(),
    Value<List<Uuid>?> defaultContacts = const Value.absent(),
    Value<List<Uuid>?> defaultGroups = const Value.absent(),
    Value<String?> defaultInviteEmails = const Value.absent(),
    bool? draft,
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
        path: path ?? this.path,
        topOrder: topOrder,
        order: order,
        pomodoro: pomodoro,
        color: color,
        key: key,
        root: root,
        teamId: teamId,
        unread: unread,
        role: role,
        attentionWindow: attentionWindow,
        seeWithinRequests: seeWithinRequests,
        seeWithinUpdates: seeWithinUpdates,
        attentionWindowSet: attentionWindowSet,
        seeWithinRequestsSet: seeWithinRequestsSet,
        seeWithinUpdatesSet: seeWithinUpdatesSet,
        config: config,
        defaultContacts: defaultContacts,
        defaultGroups: defaultGroups,
        defaultInviteEmails: defaultInviteEmails,
      ),
      parent: currentParent,
      children: children,
      draft: newDraft,
      ancestors: _ancestors,
      minAncestorTopOrder: minAncestorTopOrder,
      originalPath: _originalPath,
      active: _activeComputed,
      unreadComputed: _unreadComputed,
    );
  }

  void _removeFromParent(Priority parent) {
    parent.children = parent.children.where((child) => child.id != id).toList();
  }

  void _addChild(Priority child) {
    children = List<Priority>.from(
      children,
    ).replaceSorted(child, (a, b) => a.id == b.id);
  }

  bool isParent(Priority other) => path.isParent(other.path);
  List<Priority> get peers => parent?.children ?? [];

  /// Compute what the path should be based on the current parent.
  /// Preserves the priority's own label (last segment of path).
  Path _computePathFromParent() {
    // Extract this priority's label (last segment of path)
    final segments = path.value.split('.');
    final label = segments.last;

    // Compute new path based on parent
    if (parent == null) {
      // Moving to root is never allowed. If parent is null, it means the
      // in-memory parent field isn't populated, so keep the original path.
      return _originalPath ?? path;
    } else {
      // Moving to a parent - combine parent path + label
      return Path('${parent!.path.value}.$label');
    }
  }

  /// Check if the parent has changed since the priority was loaded from the database.
  bool _hasParentChanged() {
    // New priorities don't have an original path yet
    if (_originalPath == null) return false;

    // Compare original path with what the path should be based on current parent
    final computedPath = _computePathFromParent();
    return _originalPath!.value != computedPath.value;
  }

  /// Validate that moving to the new parent won't create a circular reference.
  /// Throws an exception if the new parent is a descendant of this priority.
  void _validateNoCircularReference(Path newPath) {
    if (_originalPath == null) {
      return; // New priorities can't have circular refs
    }

    // Check if the new path would make this priority its own descendant
    // This happens if the new parent path starts with the original path
    if (parent != null && _originalPath!.isParent(parent!.path)) {
      throw ArgumentError(
        'Cannot move priority to be its own descendant. '
        'Original path: ${_originalPath!.value}, '
        'New parent path: ${parent!.path.value}',
      );
    }
  }

  /// Find all descendants of a priority with the given path.
  /// Returns all priorities whose path starts with the given path (excluding the priority itself).
  Future<List<Priority>> _findDescendants(Path ancestorPath) async {
    final query = Store.get.select(table)
      ..where((t) => t.path.like('${ancestorPath.value}.%'));
    return query.map(Priority.fromStore).get();
  }

  /// Update paths when a priority is moved to a new parent.
  /// This handles updating both this priority and all its descendants.
  Future<void> _updatePathsForMove() async {
    final oldPath = _originalPath!;
    final newPath = _computePathFromParent();

    // Validate that non-root priorities cannot be moved to root level
    if (!root && newPath.isRoot) {
      throw ArgumentError(
        'Cannot move priority to root level. '
        'Only the priority created with root=true can have a root-level path. '
        'Attempted to change path from "${oldPath.value}" to "${newPath.value}".',
      );
    }

    // Validate no circular reference
    _validateNoCircularReference(newPath);

    // Find all descendants
    final descendants = await _findDescendants(oldPath);

    // Update all descendant paths
    for (final descendant in descendants) {
      final updatedPath = descendant.path.replacePrefix(oldPath, newPath);
      final updatedDescendant = descendant.copyWith(
        path: updatedPath,
        pending: const Value(2),
      );
      await Store.get.save(
        table,
        updatedDescendant.toCompanion(false),
        PrioritiesBase(),
      );
    }

    // Update this priority's path
    final updatedPriority = copyWith(path: newPath, pending: const Value(2));
    await Store.get.save(
      table,
      updatedPriority.toCompanion(false),
      PrioritiesBase(),
    );
  }

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
    } else {
      // Check if parent has changed and update paths if needed
      if (_hasParentChanged()) {
        await _updatePathsForMove();
        // Return updated priority with new path
        // Set pending to trigger sync of the path change
        return copyWith(
          path: _computePathFromParent(),
          pending: const Value(2),
        );
      } else {
        // No parent change, save normally
        await Store.get.save(table, toCompanion(false), PrioritiesBase());
        return this;
      }
    }
  }

  @override
  int compareTo(Priority other) {
    // Get effective topOrder (considering ancestry) for both priorities
    final thisEffectiveOrder = effectiveTopOrder;
    final otherEffectiveOrder = other.effectiveTopOrder;

    // Sort by effective topOrder if both have it
    if (thisEffectiveOrder != null && otherEffectiveOrder != null) {
      final orderCompare = thisEffectiveOrder.value.compareTo(
        otherEffectiveOrder.value,
      );
      if (orderCompare != 0) return orderCompare;
    }

    // If only one has effective topOrder, that one comes first
    if (thisEffectiveOrder != null && otherEffectiveOrder == null) return -1;
    if (thisEffectiveOrder == null && otherEffectiveOrder != null) return 1;

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
