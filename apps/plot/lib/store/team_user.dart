part of 'store.dart';

/// Local mirror of the server's `user.team_user` view.
///
/// One row per team the current user belongs to.
/// [archivedAt] is set when the user leaves (or is removed from) the team.
/// [seq] is the server's xid8 transaction ID, used for incremental sync cursors.
@DataClassName('TeamUserRow')
class TeamUsers extends Table with SyncableTable, DeletableTable {
  Int64Column get id => int64()();
  TextColumn get userId => text()();
  Int64Column get teamId => int64()();
  TextColumn get role => text()();
  TextColumn get teamName => text()();

  /// Server-side xid8 cursor, serialized as a decimal string.
  TextColumn get seq => text().withDefault(const Constant('0'))();

  @override
  Set<Column> get primaryKey => {id};
}

class TeamUsersBase extends BaseTable {
  TeamUsersBase()
    : super(
        table: 'user_team_user',
        syncEndpoint: 'team-users',
        name: 'team_users',
        order: 'updated_at',
        // team_user has no updated_at on the server; we always use the seq
        // cursor so this field is only relevant for legacy non-seq pulls
        // which this entity doesn't support.
      );

  @override
  Map<String, dynamic> toBase(DataClass row) {
    throw UnsupportedError('TeamUser is read-only');
  }

  @override
  Insertable<TeamUserRow> fromBase(Map<String, dynamic> json) {
    // Server sends user_id but we don't need it as a local FK (it's always
    // the current user). Keep it for the Drift row so it round-trips cleanly.
    // The server view has no updated_at; supply now() so SyncableTable's
    // updatedAt column (which is local-only) is always populated.
    json['updated_at'] ??= DateTime.now().toIso8601String();

    // Drift's default serializer can't cast int/String → BigInt; convert.
    if (json['id'] is int) json['id'] = BigInt.from(json['id'] as int);
    if (json['team_id'] is int) json['team_id'] = BigInt.from(json['team_id'] as int);
    if (json['id'] is String) json['id'] = BigInt.parse(json['id'] as String);
    if (json['team_id'] is String) json['team_id'] = BigInt.parse(json['team_id'] as String);

    // seq arrives as a numeric string from the server.
    json['seq'] ??= '0';

    // pending is not sent by the server; clear it.
    json.remove('pending');

    return TeamUserRow.fromJson(json);
  }
}

/// Domain class for team membership records.
class TeamUser {
  static TableInfo<TeamUsers, TeamUserRow> get table => Store.get.teamUsers;

  static Future<void> pull() async {
    await Store.get.pull(table, TeamUsersBase(), initial: true);
    await Store.get.pull(table, TeamUsersBase());
  }

  /// Returns all active (non-archived) team memberships for the current user.
  static Future<List<TeamUserRow>> getActive() {
    return (Store.get.select(table)
          ..where((t) => t.archivedAt.isNull()))
        .get();
  }

  /// Returns the team membership row for a given [teamId], or null if the
  /// current user is not (or is no longer) a member of that team.
  static Future<TeamUserRow?> getForTeam(BigInt teamId) {
    return (Store.get.select(table)
          ..where((t) => t.teamId.equals(teamId))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Watch all active team memberships. Emits whenever membership changes
  /// (e.g. after the sync handler delivers a team-leave transition).
  static Stream<List<TeamUserRow>> watchActive() {
    return (Store.get.select(table)
          ..where((t) => t.archivedAt.isNull()))
        .watch();
  }
}
