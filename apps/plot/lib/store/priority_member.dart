part of 'store.dart';

@DataClassName('PriorityMemberRow')
class PriorityMembers extends Table
    with SyncableTable, CreatedTable, DeletableTable {
  BlobColumn get contactId => blob().map(const ActorIdConverter())();
  BlobColumn get priorityId =>
      blob().map(const UuidConverter()).references(Priorities, #id)();
  TextColumn get status => text()(); // 'accepted' or 'invited'
  BlobColumn get invitedBy => blob().map(const UuidConverter()).nullable()();
  BoolColumn get personal => boolean().withDefault(const Constant(false))();
  TextColumn get role => text().withDefault(const Constant('member'))();

  @override
  Set<Column> get primaryKey => {contactId, priorityId};
}

class PriorityMembersBase extends BaseTable {
  PriorityMembersBase()
    : super(
        table: 'priority_member',
        syncEndpoint: 'priority-members',
        name: "priority_members",
        order: 'created_at',
        ascending: false,
        cursorColumn: 'contact_id',
      );

  @override
  Insertable<PriorityMemberRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    json.remove('sync_depth');
    return PriorityMemberRow.fromJson(json);
  }
}

class PriorityMember extends PriorityMemberRow {
  static $PriorityMembersTable get table => Store.get.priorityMembers;

  static Future<bool> push() => Store.get.push(table, PriorityMembersBase());

  static Future<void> pull() async {
    await Store.get.pull(table, PriorityMembersBase(), initial: true);
    await Store.get.pull(table, PriorityMembersBase());
  }

  PriorityMember(PriorityMemberRow row)
    : super(
        contactId: row.contactId,
        priorityId: row.priorityId,
        status: row.status,
        invitedBy: row.invitedBy,
        personal: row.personal,
        role: row.role,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        archivedAt: row.archivedAt,
        pending: row.pending,
      );

  /// Get all members (accepted + invited) for a priority
  static Future<List<PriorityMemberRow>> getForPriority(Uuid priorityId) async {
    final db = Store.get;
    return await (db.select(db.priorityMembers)..where(
          (pm) =>
              pm.priorityId.equalsValue(priorityId) & pm.archivedAt.isNull(),
        ))
        .get();
  }

  /// Get accepted members only
  static Future<List<PriorityMemberRow>> getAcceptedForPriority(
    Uuid priorityId,
  ) async {
    final db = Store.get;
    return await (db.select(db.priorityMembers)..where(
          (pm) =>
              pm.priorityId.equalsValue(priorityId) &
              pm.status.equals('accepted') &
              pm.archivedAt.isNull(),
        ))
        .get();
  }

  /// Get accepted members with 'member' role only
  static Future<List<PriorityMemberRow>> getAcceptedMembersForPriority(
    Uuid priorityId,
  ) async {
    final db = Store.get;
    return await (db.select(db.priorityMembers)..where(
          (pm) =>
              pm.priorityId.equalsValue(priorityId) &
              pm.status.equals('accepted') &
              pm.role.equals('member') &
              pm.archivedAt.isNull(),
        ))
        .get();
  }

  /// Get accepted members with 'viewer' role only
  static Future<List<PriorityMemberRow>> getAcceptedViewersForPriority(
    Uuid priorityId,
  ) async {
    final db = Store.get;
    return await (db.select(db.priorityMembers)..where(
          (pm) =>
              pm.priorityId.equalsValue(priorityId) &
              pm.status.equals('accepted') &
              pm.role.equals('viewer') &
              pm.archivedAt.isNull(),
        ))
        .get();
  }

  /// Get invited members only
  static Future<List<PriorityMemberRow>> getInvitedForPriority(
    Uuid priorityId,
  ) async {
    final db = Store.get;
    return await (db.select(db.priorityMembers)..where(
          (pm) =>
              pm.priorityId.equalsValue(priorityId) &
              pm.status.equals('invited') &
              pm.archivedAt.isNull(),
        ))
        .get();
  }
}
