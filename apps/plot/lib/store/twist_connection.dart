part of 'store.dart';

/// Local mirror of the `user.twist_connection` view.
///
/// One row per (twist_instance, user, provider, actor_id) — the per-account
/// status surface for connections (re-auth needed, initial sync running, etc.).
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
  Set<Column> get primaryKey => {twistInstanceId, provider, actorId};
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
    return Store.get.select(table).watch();
  }

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
