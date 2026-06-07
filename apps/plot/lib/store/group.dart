part of 'store.dart';

@DataClassName('GroupRow')
class Groups extends Table with SyncableTable, UuidTable, DeletableTable {
  TextColumn get name => text()();
  TextColumn get type => text()();

  /// Stable identifier for system-managed groups (e.g. `@plot.team`). Synced
  /// from `user.group.key` so the client can resolve the Plot Team group
  /// offline (used by Help & Feedback). Null for user-created groups.
  TextColumn get key => text().nullable()();
  TextColumn get joinPolicy => text()();
  IntColumn get teamId => integer().nullable()();
  BoolColumn get autoMaintained =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isAdmin => boolean().withDefault(const Constant(false))();
  BoolColumn get isMember => boolean().withDefault(const Constant(false))();
  BoolColumn get canPost => boolean().withDefault(const Constant(false))();

  /// Group privacy: `open` or `private`. Synced from `user.group.privacy`.
  TextColumn get privacy => text().nullable()();

  /// May the user add this group to a thread/topic. Synced from
  /// `user.group.can_address`.
  BoolColumn get canAddress => boolean().withDefault(const Constant(false))();

  TextColumn get memberContactIds =>
      text().nullable().map(const UuidListConverter())();

  /// LOCAL-ONLY intent flag (not part of the server `user.group` view, never
  /// synced down). Marks that a genuine membership change is pending for this
  /// row, so [GroupsBase.toBase] should send `member_contact_ids` (triggering
  /// the server's full-set diff). Nullable so [GroupRow.fromJson] tolerates the
  /// key being absent from a pulled server payload — a pulled row therefore
  /// lands with `membersDirty == null` (not dirty), resetting the flag. Treat
  /// null as "not dirty".
  BoolColumn get membersDirty => boolean().nullable()();
}

class GroupsBase extends BaseTable {
  GroupsBase() : super(table: 'user_group', syncEndpoint: 'groups');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    // Minimal payload save_group consumes. Computed columns (isAdmin, canPost,
    // ...) are server-derived and not sent.
    final group = row as GroupRow;
    final payload = <String, dynamic>{
      'id': group.id.toString(),
      'name': group.name,
      'privacy': group.privacy,
    };
    // Only send the membership set for genuine membership operations. Omitting
    // the key makes the server skip its full-set diff (its `p_group ?
    // 'member_contact_ids'` guard), so a plain rename can't remove members that
    // another device added but we haven't pulled yet.
    if (group.membersDirty == true) {
      payload['member_contact_ids'] =
          group.memberContactIds?.map((u) => u.toString()).toList() ??
          <String>[];
    }
    return payload;
  }

  @override
  Insertable<GroupRow> fromBase(Map<String, dynamic> json) {
    return GroupRow.fromJson(json);
  }
}

class Group {
  static TableInfo<Groups, GroupRow> get table => Store.get.groups;

  // In-memory cache for synchronous lookups. Groups are small (typically a
  // handful per user) so we keep the full set in memory and refresh after
  // each pull.
  static final Map<Uuid, GroupRow> _cache = {};

  static Future<bool> push() async {
    return Store.get.push(table, GroupsBase());
  }

  static Future<void> pull() async {
    await Store.get.pull(table, GroupsBase(), initial: true);
    await Store.get.pull(table, GroupsBase());
    await _refreshCache();
  }

  static Future<void> _refreshCache() async {
    final rows = await Store.get.select(table).get();
    _cache
      ..clear()
      ..addEntries(rows.map((r) => MapEntry(r.id, r)));
  }

  /// Synchronous cache lookup. Returns null if the group hasn't been pulled
  /// yet (callers needing definitive resolution should fall back to
  /// [getOne]).
  static GroupRow? fromCache(Uuid id) => _cache[id];

  /// The Plot Team group, resolved by its stable `@plot.team` key. Synced to
  /// every user (see `user.group`) so Help & Feedback can share a new thread
  /// with the Plot team offline. Returns null if it hasn't synced yet (e.g.
  /// a dev environment without the Plot team seeded) — callers fall back to
  /// the welcome thread's group.
  static Future<GroupRow?> plotTeam() async {
    final cached = _cache.values.firstWhereOrNull(
      (g) => g.key == '@plot.team' && g.archivedAt == null,
    );
    if (cached != null) return cached;
    return (Store.get.select(table)
          ..where((t) => t.key.equals('@plot.team') & t.archivedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
  }

  /// The group a Help & Feedback thread should be shared with so it reaches
  /// the Plot team. Prefers the `@plot.team`-keyed group (synced to every
  /// user); falls back to whatever group the seeded "Welcome to Plot!" thread
  /// is shared with — the same Plot-team channel, present in every
  /// environment (including dev databases without a seeded Plot team). Returns
  /// null only if neither is available locally. Fully offline.
  static Future<Uuid?> feedbackTargetId() async {
    final team = await plotTeam();
    if (team != null) return team.id;
    // Fallback: the per-user "Welcome to Plot!" thread is shared with the same
    // Plot-team group. The client doesn't sync the thread `key`, so match by
    // its (distinctive) seeded title. Used in dev environments without a
    // seeded Plot team; prod resolves via the `@plot.team` key above.
    final welcome =
        await (Store.get.select(Store.get.threads)
              ..where(
                (t) =>
                    t.title.equals('Welcome to Plot!') & t.archivedAt.isNull(),
              )
              ..limit(1))
            .getSingleOrNull();
    final groups = welcome?.groups;
    return (groups != null && groups.isNotEmpty) ? groups.first : null;
  }

  /// Fetch a group by id. Returns null if the user can't see the group.
  static Future<GroupRow?> getOne(Uuid id) async {
    final cached = _cache[id];
    if (cached != null) return cached;
    final row =
        await (Store.get.select(table)
              ..where((t) => t.id.equals(id.toBytes()))
              ..limit(1))
            .getSingleOrNull();
    if (row != null) _cache[row.id] = row;
    return row;
  }

  /// Watch a group by id. Emits null until the group is synced.
  static Stream<GroupRow?> watchOne(Uuid id) {
    return (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes()))
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Groups the user is allowed to send threads to (admin of the group, or
  /// member of any non-`announce` group), filtered by [search] against name.
  ///
  /// `includeIds` forces specific groups to be included even when the user
  /// isn't a member (e.g. a read-only viewer replying to a thread addressed
  /// to a group they don't belong to), still excluding announce groups.
  ///
  /// Computed from the locally-cached `is_admin` / `is_member` / `type`
  /// columns rather than the synced `can_post` column, so the picker
  /// works immediately after the schema migration without waiting for a
  /// fresh group sync to repopulate `can_post`.
  static Future<List<GroupRow>> getPostable({
    String? search,
    List<String> includeIds = const [],
  }) async {
    // The `id` column is a UUID blob, so compare against byte values.
    final includeBytes = includeIds
        .map((id) => Uuid.fromString(id).toBytes())
        .toList();
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            (t.isAdmin.equals(true) |
                (t.isMember.equals(true) &
                    t.type.isNotIn(const ['announce'])) |
                (t.id.isIn(includeBytes) &
                    t.type.isNotIn(const ['announce']))),
      );
    if (search != null && search.isNotEmpty) {
      final lower = search.toLowerCase();
      query.where((t) => t.name.like('$lower%') | t.name.like('% $lower%'));
    }
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }
}
