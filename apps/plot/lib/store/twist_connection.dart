part of 'store.dart';

/// Local mirror of the `user.twist_connection` view.
///
/// One row per (twist_instance, provider) — the server's `twist_instance_connection`
/// PK is `(twist_instance_id, user_id, provider)` and the local store is
/// always scoped to a single user, so `actor_id` is *not* part of the PK.
/// Re-authing with a different linked email changes `actor_id` on the same
/// row; including it in the PK would leave the stale row behind on pull.
@DataClassName('TwistConnectionRow')
class TwistConnections extends Table with SyncableTable {
  BlobColumn get twistInstanceId => blob().map(const UuidConverter())();
  TextColumn get provider => text()();
  TextColumn get actorId => text()();
  DateTimeColumn get connectedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get needsReauthAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get initialSyncStartedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get initialSyncCompletedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  BoolColumn get needsReauth => boolean().withDefault(const Constant(false))();
  BoolColumn get initialSyncing =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {twistInstanceId, provider};
}

class TwistConnectionsBase extends BaseTable {
  TwistConnectionsBase()
    : super(
        table: 'user_twist_connection',
        syncEndpoint: 'twist-connections',
        name: 'twist_connections',
        order: 'updated_at',
        ascending: false,
        supportsArchiving: false,
        cursorColumn: 'twist_instance_id',
      );

  @override
  Insertable<TwistConnectionRow> fromBase(Map<String, dynamic> json) {
    json.remove('user_id');
    // Default missing booleans (older server payloads might omit them).
    json['needs_reauth'] ??= false;
    json['initial_syncing'] ??= false;
    return TwistConnectionRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('updated_by');
    json.remove('user_id');
    return json;
  }
}

class TwistConnection {
  static $TwistConnectionsTable get table => Store.get.twistConnections;

  static Future<void> pull() async {
    await Store.get.pull(table, TwistConnectionsBase(), initial: true);
    await Store.get.pull(table, TwistConnectionsBase());
  }

  static Stream<List<TwistConnectionRow>> watchAll() {
    // Defensive check: Return empty stream if Store is not available (user signing out)
    if (!Injector.appInstance.exists<Store>()) {
      return Stream.value(const []);
    }
    return Store.get.select(table).watch();
  }

  /// Filters [connections] to those that still have at least one enabled
  /// channel (their `twistInstanceId` is in [enabledInstanceIds]).
  ///
  /// A connection whose channels are all disabled is dormant: the
  /// manage-connections modal hides it (`enabledCount == 0`) and the server
  /// excludes it from quota counts (`getPersonalConnectionCount` /
  /// `getTeamConnectionCount`). So such a connection must not drive the
  /// "Reconnect" / "Syncing" prompts — otherwise a disabled connection that
  /// still carries `needs_reauth_at` nags forever with no row to act on.
  static Iterable<TwistConnectionRow> active(
    Iterable<TwistConnectionRow> connections,
    Set<TwistInstanceId> enabledInstanceIds,
  ) =>
      connections.where((c) => enabledInstanceIds.contains(c.twistInstanceId));

  static Stream<List<TwistConnectionRow>> watchForInstance(
    TwistInstanceId twistInstanceId,
  ) {
    return (Store.get.select(table)
          ..where((t) => t.twistInstanceId.equals(twistInstanceId.toBytes())))
        .watch();
  }

  static Future<List<TwistConnectionRow>> getForInstance(
    TwistInstanceId twistInstanceId,
  ) {
    return (Store.get.select(table)
          ..where((t) => t.twistInstanceId.equals(twistInstanceId.toBytes())))
        .get();
  }
}
