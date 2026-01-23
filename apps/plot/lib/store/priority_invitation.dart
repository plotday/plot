part of 'store.dart';

@DataClassName('PriorityInvitationRow')
class PriorityInvitations extends Table
    with SyncableTable, CreatedTable, DeletableTable {
  BlobColumn get id => blob().map(const UuidConverter())();
  BlobColumn get priorityId =>
      blob().map(const UuidConverter()).references(Priorities, #id)();
  BlobColumn get contactId => blob().map(const UuidConverter())();
  BlobColumn get invitedBy => blob().map(const UuidConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

class PriorityInvitationsBase extends BaseTable {
  PriorityInvitationsBase()
      : super(
          table: 'priority_invitation',
          name: 'priority_invitations',
          order: 'created_at',
          ascending: false,
        );

  @override
  Insertable<PriorityInvitationRow> fromBase(Map<String, dynamic> json) {
    return PriorityInvitationRow.fromJson(json);
  }

  @override
  PostgrestFilterBuilder<T2> filter<T2>(
    PostgrestFilterBuilder<T2> query, {
    bool initial = false,
    bool archived = false,
  }) {
    // No user_id filter - RLS policies handle access control
    // Users see invitations they created (via user_has_priority_access)
    // and invitations they received (via contact_id)
    return query;
  }
}

class PriorityInvitation extends PriorityInvitationRow {
  static $PriorityInvitationsTable get table => Store.get.priorityInvitations;

  static Future<bool> push() =>
      Store.get.push(table, PriorityInvitationsBase());

  static Future<void> pull() async {
    await Store.get.pull(table, PriorityInvitationsBase(), initial: true);
    await Store.get.pull(table, PriorityInvitationsBase());
  }

  PriorityInvitation(PriorityInvitationRow row)
      : super(
          id: row.id,
          priorityId: row.priorityId,
          contactId: row.contactId,
          invitedBy: row.invitedBy,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          archivedAt: row.archivedAt,
          pending: row.pending,
        );

  Future<void> save() async {
    await Store.get.save(table, toCompanion(false), PriorityInvitationsBase());
  }

  /// Get all invitations for a specific priority (non-archived only).
  static Future<List<PriorityInvitationRow>> getForPriority(
      Uuid priorityId) async {
    final db = Store.get;
    return await (db.select(db.priorityInvitations)
          ..where((pi) =>
              pi.priorityId.equalsValue(priorityId) & pi.archivedAt.isNull()))
        .get();
  }

  /// Get all pending invitations for the current user (as invitee).
  /// Uses the current user's actor ID which is their contact ID.
  static Future<List<PriorityInvitationRow>> getMyPendingInvitations() async {
    final db = Store.get;
    // Base.actorId is the contact_id for the current user
    final myContactId = Base.actorId.toUuid();

    return await (db.select(db.priorityInvitations)
          ..where((pi) =>
              pi.contactId.equalsValue(myContactId) & pi.archivedAt.isNull()))
        .get();
  }
}
