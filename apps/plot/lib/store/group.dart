part of 'store.dart';

@DataClassName('GroupRow')
class Groups extends Table with SyncableTable, UuidTable, DeletableTable {
  TextColumn get name => text()();
  TextColumn get type => text()();
  TextColumn get joinPolicy => text()();
  IntColumn get teamId => integer().nullable()();
  BoolColumn get autoMaintained =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isAdmin => boolean().withDefault(const Constant(false))();
  BoolColumn get isMember => boolean().withDefault(const Constant(false))();
  BoolColumn get canPost => boolean().withDefault(const Constant(false))();
  TextColumn get memberContactIds =>
      text().nullable().map(const UuidListConverter())();
}

class GroupsBase extends BaseTable {
  GroupsBase() : super(table: 'user_group', syncEndpoint: 'groups');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    throw UnsupportedError('Group is read-only');
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

  /// Fetch a group by id. Returns null if the user can't see the group.
  static Future<GroupRow?> getOne(Uuid id) async {
    final cached = _cache[id];
    if (cached != null) return cached;
    final row = await (Store.get.select(table)
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
  /// Computed from the locally-cached `is_admin` / `is_member` / `type`
  /// columns rather than the synced `can_post` column, so the picker
  /// works immediately after the schema migration without waiting for a
  /// fresh group sync to repopulate `can_post`.
  static Future<List<GroupRow>> getPostable({String? search}) async {
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            (t.isAdmin.equals(true) |
                (t.isMember.equals(true) &
                    t.type.isNotIn(const ['announce']))),
      );
    if (search != null && search.isNotEmpty) {
      final lower = search.toLowerCase();
      query.where(
        (t) => t.name.like('$lower%') | t.name.like('% $lower%'),
      );
    }
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }
}
