part of 'store.dart';

@DataClassName('PriorityUserRow')
class PriorityUsers extends Table
    with SyncableTable, CreatedTable, DeletableTable {
  BlobColumn get userId => blob().map(const UuidConverter())();
  BlobColumn get priorityId =>
      blob().map(const UuidConverter()).references(Priorities, #id)();

  @override
  Set<Column> get primaryKey => {userId, priorityId};
}

class PriorityUsersBase extends BaseTable {
  PriorityUsersBase()
      : super(
          table: 'priority_user',
          name: "priority_users",
          order: 'created_at',
          ascending: false,
        );

  @override
  Insertable<PriorityUserRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    return PriorityUserRow.fromJson(json);
  }
}

class PriorityUser extends PriorityUserRow {
  static $PriorityUsersTable get table => Store.get.priorityUsers;

  static Future<bool> push() => Store.get.push(table, PriorityUsersBase());

  static Future<void> pull() async {
    await Store.get.pull(table, PriorityUsersBase(), initial: true);
    await Store.get.pull(table, PriorityUsersBase());
  }

  PriorityUser(PriorityUserRow row)
      : super(
          userId: row.userId,
          priorityId: row.priorityId,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          archivedAt: row.archivedAt,
          pending: row.pending,
        );

  Future<void> save() async {
    await Store.get.save(table, toCompanion(false), PriorityUsersBase());
  }

  /// Get all user IDs that have access to a specific priority (including inherited access).
  /// This checks both direct access and access inherited from ancestor priorities.
  static Future<List<Uuid>> getSharedUsers(Uuid priorityId) async {
    final db = Store.get;

    // Get the target priority to check its path
    final targetPriority = await (db.select(db.priorities)
          ..where((p) => p.id.equalsValue(priorityId)))
        .getSingleOrNull();

    if (targetPriority == null) return [];

    // Find all priorities that are ancestors (their path is a prefix of target's path)
    // or the target itself
    final ancestorPriorities = await (db.select(db.priorities)
          ..where((p) {
            // Check if this priority's path is a prefix of the target's path
            // In ltree terms: ancestor.path <@ target.path means target is descendant
            // We want the reverse: find all priorities where target.path starts with their path
            return p.path.isNotNull();
          }))
        .get();

    final ancestorIds = ancestorPriorities
        .where((p) =>
            p.path != null &&
            (targetPriority.path?.value.startsWith(p.path!.value) ?? false))
        .map((p) => p.id)
        .toSet();

    if (ancestorIds.isEmpty) return [];

    // Get all non-archived priority_user entries for these ancestor priorities
    final sharedUsers = await (db.select(db.priorityUsers)
          ..where((pu) =>
              pu.priorityId.isIn(ancestorIds.map((id) => id.toBytes()).toList()) &
              pu.archivedAt.isNull()))
        .get();

    return sharedUsers.map((pu) => pu.userId).toSet().toList();
  }

  /// Check if a specific user has access to a priority (direct or inherited).
  static Future<bool> hasAccess(Uuid userId, Uuid priorityId) async {
    final sharedUsers = await getSharedUsers(priorityId);
    return sharedUsers.contains(userId);
  }

  /// Get all priority_user entries for a specific priority (direct access only).
  static Future<List<PriorityUserRow>> getForPriority(Uuid priorityId) async {
    final db = Store.get;
    return await (db.select(db.priorityUsers)
          ..where((pu) =>
              pu.priorityId.equalsValue(priorityId) & pu.archivedAt.isNull()))
        .get();
  }

  /// Get all priorities shared with a specific user (direct access only).
  static Future<List<Uuid>> getPrioritiesForUser(Uuid userId) async {
    final db = Store.get;
    final entries = await (db.select(db.priorityUsers)
          ..where((pu) =>
              pu.userId.equalsValue(userId) & pu.archivedAt.isNull()))
        .get();
    return entries.map((e) => e.priorityId).toList();
  }
}
