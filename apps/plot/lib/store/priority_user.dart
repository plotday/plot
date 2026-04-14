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
          syncEndpoint: 'priority-users',
          name: "priority_users",
          order: 'created_at',
          ascending: false,
          cursorColumn: 'user_id',
        );

  @override
  Insertable<PriorityUserRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    return PriorityUserRow.fromJson(json);
  }
}

class PriorityUser extends PriorityUserRow {
  static $PriorityUsersTable get table => Store.get.priorityUsers;

  static Future<bool> push() => Store.get.push(table, PriorityUsersBase());

  static Future<void> pull() async {
    await Store.get.pull(table, PriorityUsersBase(), initial: true);
    await Store.get.pull(table, PriorityUsersBase());
    // After pull, delete local data for priorities we no longer have access to
    await _cleanupArchivedPriorities();
  }

  /// Deletes local data for any priority tree where the user's access has been revoked.
  /// This handles both explicit share removals and priority moves that displaced the user.
  static Future<void> _cleanupArchivedPriorities() async {
    final db = Store.get;
    final archivedEntries = await (db.select(db.priorityUsers)
          ..where((pu) => pu.archivedAt.isNotNull()))
        .get();

    for (final entry in archivedEntries) {
      final priority = await (db.select(db.priorities)
            ..where((p) => p.id.equalsValue(entry.priorityId)))
          .getSingleOrNull();
      if (priority != null) {
        await _cascadeDeletePriorityTree(db, priority.path.value);
      }
    }
  }

  /// Deletes all local data for a priority tree (self + descendants):
  /// note tags, thread tags, thread exceptions, notes, threads,
  /// priority twists, and the priorities themselves.
  ///
  /// Sessions are intentionally left intact as user focus history.
  static Future<void> _cascadeDeletePriorityTree(
      Store db, String rootPath) async {
    // Find all priorities in this tree (root + descendants)
    final allPriorities = await db.select(db.priorities).get();
    final treePriorities = allPriorities.where((p) {
      final pPath = p.path.value;
      return pPath == rootPath || pPath.startsWith('$rootPath.');
    }).toList();

    final treeIdBytes = treePriorities.map((p) => p.id.toBytes()).toList();
    if (treeIdBytes.isEmpty) return;

    // Find all threads in this tree
    final threads = await (db.select(db.threads)
          ..where((a) => a.priorityId.isIn(treeIdBytes)))
        .get();
    final threadIdBytes = threads.map((a) => a.id.toBytes()).toList();

    // Find all notes in this tree (needed for note tag cleanup)
    List<Uint8List> noteIdBytes = [];
    if (threadIdBytes.isNotEmpty) {
      final notes = await (db.select(db.notes)
            ..where((n) => n.threadId.isIn(threadIdBytes)))
          .get();
      noteIdBytes = notes.map((n) => n.id.toBytes()).toList();
    }

    // Delete in FK-safe order
    if (noteIdBytes.isNotEmpty) {
      await (db.delete(db.noteTags)
            ..where((nt) => nt.id.isIn(noteIdBytes)))
          .go();
    }
    if (threadIdBytes.isNotEmpty) {
      await (db.delete(db.threadTags)
            ..where((at) => at.id.isIn(threadIdBytes)))
          .go();
      await (db.delete(db.schedules)
            ..where((s) => s.threadId.isIn(threadIdBytes)))
          .go();
      await (db.delete(db.notes)
            ..where((n) => n.threadId.isIn(threadIdBytes)))
          .go();
      await (db.delete(db.threads)
            ..where((a) => a.priorityId.isIn(treeIdBytes)))
          .go();
    }

    // twist_instances are workspace-level and not tied to priorities, so they
    // are not deleted along with the priority subtree.

    // Delete priorities deepest-first to respect any FK constraints
    final sorted = List<PriorityRow>.from(treePriorities)
      ..sort((a, b) => b.path.value.length.compareTo(a.path.value.length));
    for (final p in sorted) {
      await (db.delete(db.priorities)
            ..where((row) => row.id.equalsValue(p.id)))
          .go();
    }
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
