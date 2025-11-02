import 'dart:async';
import 'dart:math';

import 'dart:convert';
import 'package:flutter/widgets.dart' show IconData;
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:collection/collection.dart';
import 'package:injector/injector.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:remove_markdown/remove_markdown.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:equatable/equatable.dart';
import 'package:rrule/rrule.dart';
import 'package:synchronized/synchronized.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/async.dart';
import 'package:plot/util/string.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/agent_api.dart';
import 'package:plot/api/broadcast.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/base.dart';
import 'enums.dart';
import 'types.dart';
import 'logging.dart';

export 'package:plot/util/value.dart';
export 'package:plot/util/time.dart';
export 'package:plot/util/uuid.dart';
export 'package:plot/util/order.dart';
export 'package:plot/util/path.dart';
export 'package:plot/base.dart';
export 'schedule.dart';
export 'enums.dart';

part 'sync.dart';
part 'actor.dart';
part 'priority.dart';
part 'activity.dart';
part 'activity_exception.dart';
part 'activity_tags.dart';
part 'session.dart';
part 'tag.dart';

part 'store.g.dart';

mixin SyncableTable on Table {
  DateTimeColumn get updatedAt => dateTime()
      .withDefault(currentDateAndTime)
      .map(const LocalDateTimeConverter())();
  IntColumn get pending => integer().nullable()();
}

mixin CreatedTable on Table {
  DateTimeColumn get createdAt => dateTime()
      .withDefault(currentDateAndTime)
      .map(const LocalDateTimeConverter())();
}

mixin DraftTable on Table {
  BoolColumn get draft => boolean().withDefault(const Constant(false))();
}

mixin DeletableTable on Table {
  DateTimeColumn get deletedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

mixin IdTable on Table {
  IntColumn get id => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

mixin UuidTable on Table {
  BlobColumn get id => blob()
      .clientDefault(() => Uuid.generate().toBytes())
      .map(const UuidConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

enum PullType {
  initial, // pull first page on initial pull
  more, // pull the next page
  updates, // pull updates since last pull
  all, // pull all
}

/// A table in the remote database that can be synced with the local database.
abstract class BaseTable {
  const BaseTable({
    required this.table,
    this.writeTable,
    this.order = 'created_at',
    this.ascending = true,
    this.upsertAsUpdate = false,
    String? name,
    this.filterName,
    this.limit,
  }) : name = name ?? "${table}s";

  final String table;

  /// Override the table for writes.
  final String? writeTable;
  final String name;
  final String? filterName;
  String get fullName => "$name${filterName == null ? "" : ":$filterName"}";
  final String order;
  final bool ascending;
  final int? limit;
  final bool upsertAsUpdate;

  Map<String, dynamic> toBase(DataClass row) {
    final json = row.toJson();
    json['updated_by'] = Store.clientId;
    json.remove('pending');
    return json;
  }

  Insertable<DataClass> fromBase(Map<String, dynamic> json);

  Future<
    (
      Iterable<Map<String, dynamic>> rows,
      DateTime? lastUpdated,
      (String?, String?)? range,
      bool more,
    )
  >
  get({String? from, String? to, DateTime? updatedSince}) async {
    var query = select();
    query = filterRange(query, from, to);
    if (updatedSince != null) {
      query = query.gt("updated_at", updatedSince);
    }
    query = filter(query);
    PostgrestTransformBuilder<PostgrestList> query2 = query;
    if (limit != null) {
      query2 = sort(query);
      query2 = query2.limit(limit!);
    }
    DateTime preQueryTimestamp = DateTime.now();
    final rows = await query2;
    (String?, String?)? range;
    if (from != null || to != null) {
      range = (from, to);
    } else if (rows.isNotEmpty) {
      range = (rows.first[order].toString(), rows.last[order].toString());
    }
    DateTime lastUpdated;
    if (rows.isEmpty) {
      final localTimestamp = DateTime.now();
      final serverTimestamp = DateTime.parse(
        await Base.client.rpc<String>('server_timestamp'),
      );
      lastUpdated = preQueryTimestamp.add(
        serverTimestamp.difference(localTimestamp),
      );
    } else {
      lastUpdated = rows
          .map((row) {
            return DateTime.parse(row['updated_at'] as String);
          })
          .reduce((value, last) => value.isAfter(last) ? value : last);
    }
    final more =
        (from != null || to != null) || (limit != null && rows.length < limit!);
    return (rows, lastUpdated, range, more);
  }

  PostgrestFilterBuilder<PostgrestList> select() {
    return Base.client.from(table).select();
  }

  PostgrestFilterBuilder<T2> filterRange<T2>(
    PostgrestFilterBuilder<T2> query,
    String? from,
    String? to,
  ) {
    if (!ascending) {
      final tmp = from;
      from = to;
      to = tmp;
    }
    if (from != null) {
      query = query.gte(order, from);
    }
    if (to != null) {
      query = query.lte(order, to);
    }
    return query;
  }

  PostgrestFilterBuilder<T2> filter<T2>(PostgrestFilterBuilder<T2> query) {
    return query.eq("user_id", Base.userId.toString());
  }

  PostgrestTransformBuilder<T2> sort<T2>(PostgrestTransformBuilder<T2> query) {
    return query.order(order, ascending: ascending);
  }

  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final id = rows.first['id'];
    if (id is int) {
      for (final row in rows) {
        final id = row['id'] as Object;
        final rest = Map<String, dynamic>.from(row)..remove('id');
        await Base.client.from(writeTable ?? table).update(rest).eq('id', id);
      }
    } else if (upsertAsUpdate) {
      await Base.client.from(writeTable ?? table).insert(rows.toList());
    } else {
      await Base.client.from(writeTable ?? table).upsert(rows.toList());
    }
  }
}

@DriftDatabase(
  tables: [
    SyncStates,
    Actors,
    Priorities,
    Activities,
    ActivityExceptions,
    ActivityTags,
    Sessions,
  ],
  include: {'priority.drift'},
)
class Store extends _$Store {
  static Store get get => Injector.appInstance.get<Store>();

  // Track ongoing push operations per table to prevent concurrent pushes
  static final Map<String, Completer<bool>> _pushCompleters = {};

  // Client ID for tracking updates to prevent sync loops
  static int? _clientId;
  static int get clientId {
    _clientId ??= 0; // Fallback if not loaded yet
    return _clientId!;
  }

  static int _generateClientId() {
    // Generate random 32-bit integer
    final Random random = Random();
    return random.nextInt(2147483647); // Max int value
  }

  static Future<void> _loadClientId() async {
    final prefs = await SharedPreferences.getInstance();
    _clientId = prefs.getInt('client_id');
    if (_clientId == null) {
      _clientId = _generateClientId();
      await prefs.setInt('client_id', _clientId!);
      log.info("Generated new client ID: $_clientId");
    } else {
      log.info("Loaded client ID: $_clientId");
    }
  }

  static Future<void> _regenerateClientId() async {
    _clientId = _generateClientId();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('client_id', _clientId!);
  }

  static Future<void> init(User user) async {
    driftRuntimeOptions.defaultSerializer = const CustomSerializer();
    await _loadClientId();
    if (Injector.appInstance.exists<Store>()) {
      await get.close();
    }
    final inst = Store._(user);
    Injector.appInstance.registerSingleton<Store>(() => inst, override: true);

    if (await Priority.hasDefault()) {
      // User has existing local data, start sync in background (non-blocking)
      inst._setupConnectivityListener();
    } else {
      // New user or no local data - need to sync before app can be used
      // Check if we're offline first to provide better error message
      if (!(await inst._hasNetworkConnectivity())) {
        throw Exception(
          "No local data available. Please connect to the internet to set up your account.",
        );
      }
      await inst._startSync();
      assert(await Priority.hasDefault(), "No default priority");
    }
  }

  BroadcastClient? _broadcastClient;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;

  Future<DATA> add<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Insertable<DATA> data,
  ) async {
    try {
      return await Store.get
          .into(table)
          .insertReturning(data, onConflict: DoUpdate((old) => data));
    } catch (e, t) {
      log.warning("Error saving ${toString()}", e, t);
      rethrow;
    }
  }

  Future<void> addBatch<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Iterable<Insertable<DATA>> data,
  ) async {
    try {
      await batch((batch) {
        batch.insertAllOnConflictUpdate(table, data);
      });
    } catch (e, t) {
      log.warning("Error saving ${toString()}", e, t);
      rethrow;
    }
  }

  Future<void> save<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Insertable<DATA> data,
    BaseTable baseTable,
  ) async {
    log.info("Saving to ${table.actualTableName}:", data);
    try {
      await add(table, data);
    } catch (e, t) {
      log.warning("Error saving ${toString()}", e, t);
      rethrow;
    }
    // Fire and forget push
    push(table, baseTable);
  }

  Future<bool> push<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable,
  ) async {
    final entity = baseTable.fullName;

    // Check if push already in progress for this table
    if (_pushCompleters.containsKey(entity)) {
      // Wait for existing push to complete
      final existingResult = await _pushCompleters[entity]!.future;

      if (existingResult) {
        // Previous push succeeded, retry this push
        return push(table, baseTable);
      } else {
        // Previous push failed, return false
        return false;
      }
    }

    // Start new push
    final completer = Completer<bool>();
    _pushCompleters[entity] = completer;

    try {
      // First fetch rows with pending changes and mark them as sync-in-progress
      final List<QueryRow> pendingRows = await customWriteReturning(
        'UPDATE ${table.actualTableName} SET pending = pending | 1 WHERE pending IS NOT NULL RETURNING *',
        updates: {table},
      );

      var success = false;
      if (pendingRows.isEmpty) {
        success = true;
      } else {
        log.info("Pushing ${pendingRows.length} ${baseTable.name} rows");

        try {
          // Try batch push first
          await baseTable.put(
            await Future.wait(
              pendingRows.map(
                (row) async => baseTable.toBase(await table.map(row.data)),
              ),
            ),
          );
          success = true;

          // On successful batch sync, clear pending for all rows with bit 1 set
          await customUpdate(
            'UPDATE ${table.actualTableName} SET pending = NULL WHERE (pending & 1) = 1',
            updates: {table},
          );
        } catch (e, trace) {
          log.warning(
            "Batch push failed, falling back to individual pushes",
            e,
            trace,
          );

          // Step 3b: On batch failure, try individual rows
          for (final row in pendingRows) {
            try {
              final data = await table.map(row.data);
              try {
                await baseTable.put([baseTable.toBase(data)]);
                success = true;
                // set pending = NULL for this row
                await customUpdate(
                  'UPDATE ${table.actualTableName} SET pending = NULL WHERE id = ?',
                  variables: [Variable(row.data['id'])],
                  updates: {table},
                );
              } catch (e, stackTrace) {
                log.warning(
                  "Error pushing ${baseTable.toBase(data)} to ${baseTable.table}",
                  e,
                  stackTrace,
                );
              }
            } catch (e, stackTrace) {
              log.warning(
                "Error parsing row ${jsonEncode(row.data)} from ${baseTable.table}",
                e,
                stackTrace,
              );
            }
          }
        }
      }

      completer.complete(success);
      return success;
    } catch (e, trace) {
      log.warning("Push failed for ${baseTable.table}", e, trace);
      completer.complete(false);
      return false;
    } finally {
      _pushCompleters.remove(entity);
    }
  }

  /// Pulls data from the remote database and syncs it to the local store.
  ///
  /// [type] determines the pull behavior:
  /// - [PullType.initial]: Fetches the first page (respects baseTable.limit) when
  ///   no sync state exists. Returns null if already initialized.
  /// - [PullType.more]: Fetches the next page (respects baseTable.limit) of older
  ///   data. Returns null if no more data or if the requested range is already fetched.
  /// - [PullType.updates]: Fetches all new/updated items since last sync. Loops
  ///   internally until all updates are pulled, ignoring baseTable.limit.
  /// - [PullType.all]: Fetches all data without pagination.
  ///
  /// [range] optionally specifies a date range to pull. For descending tables
  /// (like activities), range should be in chronological order (oldest, newest).
  /// For ascending tables, range should also be in chronological order (oldest, newest).
  ///
  /// Returns:
  /// - `null` if nothing was pulled (skipped, early exit, or no data)
  /// - `(String?, String?)` tuple representing the range that was pulled:
  ///   - For descending tables: `(oldest_value, null)` representing "from oldest to now"
  ///   - For ascending tables: `(null, newest_value)` representing "from beginning to newest"
  ///
  /// The returned range can be used to synchronize related tables to ensure they
  /// cover the exact same data range.
  Future<(String?, String?)?> pull<TABLE extends SyncableTable, DATA extends DataClass>(
    PullType type,
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    (String?, String?)? range,
  }) async {
    log.info("pull($type, ${baseTable.table}, range: $range)");
    final paged =
        [PullType.initial, PullType.more].contains(type) && range == null;
    if (paged && !hasMore(baseTable)) {
      return null;
    }
    final entity = baseTable.fullName;
    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();
    if (paged && syncState?.pulledAt != null && syncState?.last == null) {
      _noMore.add(entity);
      return null;
    }
    if (type == PullType.initial && syncState?.last != null) {
      return null;
    }
    if (type == PullType.updates && syncState?.pulledAt == null) {
      return null;
    }
    // Skip PullType.more if the requested range is already fetched
    if (type == PullType.more && range != null && syncState?.last != null) {
      // For descending tables, last represents the earliest value synced
      // Skip if range.$2 >= last (range is newer than or equal to earliest synced)
      // For ascending tables, last represents the latest value synced
      // Skip if range.$1 <= last (range is older than or equal to latest synced)
      final shouldSkip = baseTable.ascending
          ? range.$1 != null && range.$1!.compareTo(syncState!.last!) <= 0
          : range.$2 != null && range.$2!.compareTo(syncState!.last!) >= 0;
      if (shouldSkip) {
        log.info("Skipping PullType.more - range already fetched");
        return null;
      }
    }

    // For PullType.updates, loop until all updates are fetched
    var totalRows = 0;
    var currentLast = syncState?.last;
    var more = false;
    DateTime? lastUpdated;

    do {
      final requestFrom = range != null
          ? range.$1
          : ((baseTable.ascending
                    ? type == PullType.more
                    : type == PullType.updates)
                ? currentLast
                : null);
      final requestTo = range != null
          ? range.$2
          : ((baseTable.ascending
                    ? type == PullType.updates
                    : type == PullType.more)
                ? currentLast
                : null);
      log.info("Requesting from $requestFrom to $requestTo");
      var (baseRows, batchLastUpdated, newRange, batchMore) = (await baseTable.get(
        from: requestFrom,
        to: requestTo,
        updatedSince: type == PullType.updates ? syncState?.pulledAt : null,
      ));
      final (from, to) = newRange ?? (null, null);
      more = batchMore;
      if (batchLastUpdated != null) {
        lastUpdated = batchLastUpdated;
      }

      log.info(
        "Pulling ${baseRows.length} rows from ${baseTable.table} (type: $type, from: $from, to: $to, more: $more)",
      );
      final storeRows = baseRows.expand<Insertable<DataClass>>((r) {
        try {
          return [baseTable.fromBase(r)];
        } catch (e, stackTrace) {
          log.warning(
            "Error parsing row ${jsonEncode(r)} from ${baseTable.table}",
            e,
            stackTrace,
          );
          return [];
        }
      });
      await batch((batch) {
        batch.insertAllOnConflictUpdate(table, storeRows);
      });

      totalRows += baseRows.length;

      if (!more) {
        _noMore.add(entity);
      }
      final last = range != null
          ? Value(baseTable.ascending ? range.$2 : range.$1)
          : paged
          ? (more ? Value(to) : const Value(null))
          : const Value<String?>.absent();
      log.info("Last is $last");
      if (lastUpdated != null) {
        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            pulledAt: Value(lastUpdated),
            last: last,
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entity),
              pulledAt: Value(lastUpdated),
              last: last,
            ),
          ),
        );
      }

      // Update currentLast for next iteration
      if (type == PullType.updates && more) {
        currentLast = to;
      }
    } while (type == PullType.updates && more);

    log.info("Total rows pulled: $totalRows");
    // If this is the first pull for the given type, we need to set its pulledAt
    // so updates are synced from that point on.
    if (baseTable.filterName != null) {
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: baseTable.name,
          pulledAt: Value(lastUpdated),
        ),
        onConflict: DoNothing(),
      );
    }

    // Return the range that was pulled
    // For descending tables, syncState.last is the oldest boundary
    // Return (oldest, null) to represent the range from oldest to now
    final finalSyncState = await (select(syncStates)
      ..where((row) => row.entity.equals(entity))).getSingleOrNull();

    if (finalSyncState?.last != null) {
      return (finalSyncState!.last, null);
    }

    return null;
  }

  static final Set<String> _noMore = {};
  bool hasMore(BaseTable baseTable) {
    return !_noMore.contains(baseTable.fullName);
  }

  Future<void> _syncAll() async {
    try {
      await Actor.pull();
      if (!await Priority.push()) {
        log.warning("Priority push failed during _syncAll");
      }
      await Priority.pull();
      if (!await Activity.push()) {
        log.warning("Activity push failed during _syncAll");
      }
      await Activity.pullInitial();
      await Activity.pull();
      if (!await Session.push()) {
        log.warning("Session push failed during _syncAll");
      }
      await Session.pull();
    } catch (e, stackTrace) {
      log.warning("Error during _syncAll", e, stackTrace);
    }
  }

  Future<void> _handleTableSync(String table) async {
    log.info("Syncing $table");
    try {
      switch (table) {
        case 'priority':
          if (!await Priority.push()) {
            log.warning("Priority push failed during table sync");
          }
          await Priority.pull();
          break;
        case 'activity':
          if (!await Activity.push()) {
            log.warning("Activity push failed during table sync");
          }
          await Activity.pull();
          break;
        case 'session':
          if (!await Session.push()) {
            log.warning("Session push failed during table sync");
          }
          await Session.pull();
          break;
        default:
          log.warning("Unknown table update for $table");
      }
    } catch (e, stackTrace) {
      log.warning("Error handling realtime update for $table", e, stackTrace);
    }
  }

  Future<void> _subscribeToUpdates() async {
    _unsubscribeFromUpdates();

    _broadcastClient = BroadcastClient.instance;
    _broadcastClient!.init(_handleBroadcastMessage, clientId);
    await _broadcastClient!.connect();
  }

  Future<void> _handleBroadcastMessage(Map<String, dynamic> message) async {
    final table = message['table'] as String?;

    if (table == null) {
      log.warning("Received broadcast message without table field: $message");
      return;
    }

    await _handleTableSync(table);
  }

  Future<bool> _hasNetworkConnectivity() async {
    try {
      final connectivity = await Connectivity().checkConnectivity();
      return connectivity.any((result) => result != ConnectivityResult.none);
    } catch (e) {
      log.warning("Error checking connectivity: $e");
      return false;
    }
  }

  Future<void> _waitForNetworkConnectivity() async {
    if (await _hasNetworkConnectivity()) {
      return;
    }

    log.info("No network connectivity, waiting for connection...");
    final completer = Completer<void>();

    late StreamSubscription<List<ConnectivityResult>> subscription;
    subscription = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        log.info("Network connectivity restored");
        subscription.cancel();
        completer.complete();
      }
    });

    return completer.future;
  }

  Future<void> _startSync() async {
    // Prevent concurrent sync attempts
    if (_isSyncing) {
      log.info("Sync already in progress, skipping");
      return;
    }

    _isSyncing = true;
    try {
      _unsubscribeFromUpdates();
      await _waitForNetworkConnectivity();
      await _syncAll();
      await _subscribeToUpdates();
      // Sync one more time in case something changed while we were syncing, before we subscribed
      await _syncAll();
    } finally {
      _isSyncing = false;
    }
  }

  void _setupConnectivityListener() {
    // Monitor connectivity changes throughout app lifecycle
    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) async {
      final isOnline = results.any(
        (result) => result != ConnectivityResult.none,
      );

      if (isOnline && !_isSyncing) {
        log.info("Connectivity restored, attempting to sync");
        // Attempt sync when connectivity is restored (fire and forget)
        _startSync().catchError((Object error, StackTrace stackTrace) {
          log.warning("Connectivity-triggered sync failed", error, stackTrace);
          return null;
        });
      }
    });
  }

  Store._(User user)
    : super(
        driftDatabase(
          name: 'plot-${user.id}',
          web: DriftWebOptions(
            sqlite3Wasm: Uri.parse('sqlite3.wasm'),
            driftWorker: Uri.parse('drift_worker.dart.js'),
          ),
        ),
      );

  @override
  int get schemaVersion => 139;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        // Regenerate client ID on database creation to ensure clean sync state
        await _regenerateClientId();
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // Regenerate client ID on database upgrade to avoid issues with old sync state
        await _regenerateClientId();
        for (final entity in allSchemaEntities) {
          try {
            await m.drop(entity);
          } catch (e) {
            // ignore
          }
        }
        await m.createAll();
      },
    );
  }

  @override
  Future<void> close() async {
    _unsubscribeFromUpdates();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    await super.close();
  }

  void _unsubscribeFromUpdates() {
    _broadcastClient?.disconnect();
    _broadcastClient = null;
  }
}
