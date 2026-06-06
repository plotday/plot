part of 'store.dart';

@DataClassName('TopicRow')
class Topics extends Table with SyncableTable, UuidTable, DeletableTable {
  TextColumn get name => text()();

  /// Stable identifier for system topics (e.g. `@plot.updates`). Null for
  /// user-created topics.
  TextColumn get key => text().nullable()();
  TextColumn get joinPolicy => text()();
  IntColumn get teamId => integer().nullable()();
  BoolColumn get announce => boolean().withDefault(const Constant(false))();
  BoolColumn get autoMaintained =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isAdmin => boolean().withDefault(const Constant(false))();
  BoolColumn get isMember => boolean().withDefault(const Constant(false))();

  /// The viewing user has left this topic (opted out). The topic stays visible
  /// (so they can rejoin) but they don't receive its thread stream.
  BoolColumn get optedOut => boolean().withDefault(const Constant(false))();

  /// May the user post threads to this topic (admins always; non-announce members).
  BoolColumn get canPost => boolean().withDefault(const Constant(false))();

  /// May the user edit the topic's membership (admins; open-join members).
  BoolColumn get canManage => boolean().withDefault(const Constant(false))();
  TextColumn get memberContactIds =>
      text().nullable().map(const UuidListConverter())();
}

class TopicsBase extends BaseTable {
  TopicsBase() : super(table: 'user_topic', syncEndpoint: 'topics');

  @override
  Map<String, dynamic> toBase(DataClass row) {
    throw UnsupportedError('Topic is read-only');
  }

  @override
  Insertable<TopicRow> fromBase(Map<String, dynamic> json) {
    return TopicRow.fromJson(json);
  }
}

class Topic {
  static TableInfo<Topics, TopicRow> get table => Store.get.topics;

  static final Map<Uuid, TopicRow> _cache = {};

  static Future<void> pull() async {
    await Store.get.pull(table, TopicsBase(), initial: true);
    await Store.get.pull(table, TopicsBase());
    await _refreshCache();
  }

  static Future<void> _refreshCache() async {
    final rows = await Store.get.select(table).get();
    _cache
      ..clear()
      ..addEntries(rows.map((r) => MapEntry(r.id, r)));
  }

  static TopicRow? fromCache(Uuid id) => _cache[id];

  static Future<TopicRow?> getOne(Uuid id) async {
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

  static Stream<TopicRow?> watchOne(Uuid id) {
    return (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes()))
          ..limit(1))
        .watchSingleOrNull();
  }

  /// Topics the user can post to, filtered by [search]. Admins always; others
  /// only non-announce topics they're a member of and haven't left.
  static Future<List<TopicRow>> getPostable({String? search}) async {
    final query = Store.get.select(table)
      ..where(
        (t) =>
            t.archivedAt.isNull() &
            t.optedOut.equals(false) &
            (t.isAdmin.equals(true) |
                (t.isMember.equals(true) & t.announce.equals(false))),
      );
    if (search != null && search.isNotEmpty) {
      final lower = search.toLowerCase();
      query.where((t) => t.name.like('$lower%') | t.name.like('% $lower%'));
    }
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.get();
  }
}
