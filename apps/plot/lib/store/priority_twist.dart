part of 'store.dart';

typedef PriorityTwistId = Uuid;

@DataClassName('PriorityTwistRow')
class PriorityTwists extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  BlobColumn get priorityId => blob().map(const UuidConverter())();
  Int64Column get twistId => int64()(); // Changed from UUID to bigint
  TextColumn get twistEnvironment => text()(); // Read from user_twist view (JOIN with twist table)
  TextColumn get name => text()();
  TextColumn get config => text().map(const JsonConverter())();
}

class PriorityTwistsBase extends BaseTable {
  PriorityTwistsBase()
    : super(
        table: 'user_twist',
        writeTable: 'priority_twist',
        name: "priority_twists",
        order: 'created_at',
        ascending: false,
      );

  @override
  Insertable<PriorityTwistRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('owner_id');
    json.remove('user_id');
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
    return rows.map((row) => PriorityTwist(row)).toList();
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
    return query.watch().map(
      (rows) => rows.map((row) => PriorityTwist(row)).toList(),
    );
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

  PriorityTwist(PriorityTwistRow row)
      : super(
          id: row.id,
          priorityId: row.priorityId,
          twistId: row.twistId,
          twistEnvironment: row.twistEnvironment,
          name: row.name,
          config: row.config,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          archivedAt: row.archivedAt,
          pending: row.pending,
        );

  Future<void> save() async {
    await Store.get.save(
      table,
      copyWith(
        updatedAt: DateTime.now(),
      ),
      PriorityTwistsBase(),
    );
  }
}
