import 'dart:async';
import 'dart:math';

import 'dart:convert';
import 'package:flutter/widgets.dart' show IconData;
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'package:collection/collection.dart';
import 'package:injector/injector.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:remove_markdown/remove_markdown.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:b/b.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/list.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/util/async.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/base.dart';
import 'types.dart';
import 'logging.dart';

export 'package:plot/util/value.dart';
export 'package:plot/util/time.dart';
export 'package:plot/util/uuid.dart';
export 'package:plot/util/order.dart';
export 'schedule.dart';
export 'types.dart' show TagType;

part 'sync.dart';
part 'account.dart';
part 'calendar.dart';
part 'priority.dart';
part 'activity.dart';
part 'event.dart';
part 'session.dart';
part 'balance.dart';
part 'tag.dart';

part 'store.g.dart';

mixin SyncableTable on Table {
  DateTimeColumn get updatedAt => dateTime()
      .withDefault(currentDateAndTime)
      .map(const LocalDateTimeConverter())();
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
  get({
    (String?, String?)? include,
    (String?, String?)? exclude,
    DateTime? updatedSince,
  }) async {
    var query = Base.client.from(table).select();
    if (exclude != null) {
      final (from, to) = exclude;
      if (from != null) {
        if (to != null) {
          query = query.or("$order.lt.$from,$order.gt.$to");
        } else {
          query = query.lt(order, from);
        }
      } else if (to != null) {
        query = query.gt(order, to);
      }
    }
    if (include != null) {
      final (from, to) = include;
      if (from != null) {
        query = query.gte(order, from);
      }
      if (to != null) {
        query = query.lte(order, to);
      }
    }
    if (updatedSince != null) {
      query = query.gt("updated_at", updatedSince);
    }
    query = filter(query);
    var query2 = sort(query);
    if (limit != null) {
      query2 = query2.limit(limit!);
    }
    DateTime preQueryTimestamp = DateTime.now();
    final rows = await query2;
    (String?, String?)? range;
    if (include != null && limit == null) {
      range = include;
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
    final more = include != null || (limit != null && rows.length < limit!);
    return (rows, lastUpdated, range, more);
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
    Accounts,
    Calendars,
    Priorities,
    Activities,
    Events,
    Sessions,
    Balances,
  ],
  include: {'priority.drift', 'activity.drift', 'balance.drift'},
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
    log.info("Regenerated client ID: $_clientId");
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
      inst._startSync();
    } else {
      await inst._startSync();
      assert(await Priority.hasDefault(), "No default priority");
    }
  }

  RealtimeChannel? _realtimeChannel;

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
      final syncState = await (select(
        syncStates,
      )..where((row) => row.entity.equals(entity))).getSingleOrNull();

      final storeQuery = select(table);
      if (syncState?.pushedAt != null) {
        storeQuery.where((row) {
          return row.updatedAt.isBiggerThanValue(syncState!.pushedAt!);
        });
      }
      storeQuery.orderBy([(t) => OrderingTerm(expression: t.updatedAt)]);
      final now = DateTime.now();
      final storeRows = await storeQuery.get();
      var success = false;
      if (storeRows.isEmpty) {
        success = true;
      } else {
        log.info("Pushing ${storeRows.length} rows to ${baseTable.table}");
        try {
          await baseTable.put(storeRows.map((row) => baseTable.toBase(row)));
          success = true;
        } catch (e, trace) {
          log.warning("Batch push failed", e, trace);
          for (final row in storeRows) {
            try {
              await baseTable.put([baseTable.toBase(row)]);
            } catch (e, stackTrace) {
              log.warning(
                "Error pushing ${row.toJsonString()} to ${baseTable.table}",
                e,
                stackTrace,
              );
            }
          }
        }
      }
      if (success) {
        try {
          await into(syncStates).insert(
            SyncStatesCompanion.insert(entity: entity, pushedAt: Value(now)),
            onConflict: DoUpdate(
              (old) => SyncStatesCompanion(
                entity: Value(entity),
                pushedAt: Value(now),
              ),
            ),
          );
        } catch (e, trace) {
          log.warning("Updating sync state failed", e, trace);
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

  Future<bool> pull<TABLE extends SyncableTable, DATA extends DataClass>(
    PullType type,
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    (String, String)? range,
  }) async {
    final paged = [PullType.initial, PullType.more].contains(type);
    if (paged && !hasMore(baseTable)) {
      return false;
    }
    final entity = baseTable.fullName;
    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();
    if (paged && syncState?.more == false) {
      _noMore.add(entity);
      return false;
    }
    if (type == PullType.initial && syncState?.to != null) {
      return true;
    }
    if (type == PullType.updates && syncState?.pulledAt == null) {
      return true;
    }

    var (baseRows, lastUpdated, newRange, more) = (await baseTable.get(
      include:
          range ??
          ([PullType.updates, PullType.more].contains(type)
              ? (syncState?.from, syncState?.to)
              : null),
      exclude: type == PullType.more ? (syncState?.from, syncState?.to) : null,
      updatedSince: type == PullType.more ? null : syncState?.pulledAt,
    ));
    final (from, to) = newRange ?? (null, null);

    log.info(
      "Pulling ${baseRows.length} rows from ${baseTable.table} (since ${type == PullType.more ? null : syncState?.pulledAt}, include ${range ?? ([PullType.updates, PullType.more].contains(type) ? (syncState?.from, syncState?.to) : null)}, exclude ${type == PullType.more ? (syncState?.from, syncState?.to) : null})",
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

    if (!more) {
      _noMore.add(entity);
    }
    await into(syncStates).insert(
      SyncStatesCompanion.insert(
        entity: entity,
        pulledAt: Value(lastUpdated),
        from: paged ? Value(from) : const Value.absent(),
        to: paged ? Value(to) : const Value.absent(),
        more: Value(paged ? more : false),
        pushedAt: const Value(null),
      ),
      onConflict: DoUpdate(
        (old) => SyncStatesCompanion(
          entity: Value(entity),
          pulledAt: Value(lastUpdated),
          from: paged ? Value(from) : const Value.absent(),
          to: paged ? Value(to) : const Value.absent(),
          more: paged
              ? Value(more)
              : type == PullType.all
              ? const Value(false)
              : const Value.absent(),
        ),
      ),
    );
    // If this is the first pull for the given type, we need to set its pulledAt
    // so updates are synced from that point on.
    if (baseTable.filterName != null) {
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: baseTable.name,
          pulledAt: Value(lastUpdated),
          pushedAt: const Value(null),
        ),
        onConflict: DoNothing(),
      );
    }
    return more;
  }

  static final Set<String> _noMore = {};
  bool hasMore(BaseTable baseTable) {
    return !_noMore.contains(baseTable.fullName);
  }

  Future<void> _syncAll() async {
    if (!await Account.push()) {
      log.warning("Account push failed during _syncAll");
    }
    await Account.pull();
    if (!await Calendar.push()) {
      log.warning("Calendar push failed during _syncAll");
    }
    await Calendar.pull();
    if (!await Priority.push()) {
      log.warning("Priority push failed during _syncAll");
    }
    await Priority.pull();
    if (!await Event.push()) {
      log.warning("Event push failed during _syncAll");
    }
    await Event.pull();
    if (!await Activity.push()) {
      log.warning("Activity push failed during _syncAll");
    }
    await Activity.pull();
    if (!await Session.push()) {
      log.warning("Session push failed during _syncAll");
    }
    await Session.pull();
    await Balance.pull();
  }

  Future<void> _handleTableSync(String table) async {
    log.info("Syncing $table");
    try {
      switch (table) {
        case 'account':
          if (!await Account.push()) {
            log.warning("Account push failed during table sync");
          }
          await Account.pull();
          break;
        case 'calendar':
          if (!await Calendar.push()) {
            log.warning("Calendar push failed during table sync");
          }
          await Calendar.pull();
          break;
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
        case 'event':
          if (!await Event.push()) {
            log.warning("Event push failed during table sync");
          }
          await Event.pull();
          break;
        case 'session':
          if (!await Session.push()) {
            log.warning("Session push failed during table sync");
          }
          await Session.pull();
          break;
        case 'balance':
          await Balance.pull();
          break;
        default:
          log.warning("Unknown table update for $table");
      }
    } catch (e, stackTrace) {
      log.warning("Error handling realtime update for $table", e, stackTrace);
    }
  }

  void _subscribedToRealtime() {
    _unsubscribeFromRealtime();

    final userId = Base.userId.toString();
    _realtimeChannel = Base.client
        .channel('user:$userId')
        .onBroadcast(
          event: 'sync',
          callback: (message) async {
            final payload = message['payload'];
            final table = payload['table'] as String;
            final updatedBy = payload['updated_by'] as int?;

            // Ignore updates from this client to prevent sync loops
            if (updatedBy != null && updatedBy == clientId) {
              log.info(
                "Ignoring own update for table $table (client $updatedBy)",
              );
              return;
            }

            await _handleTableSync(table);
          },
        )
        .subscribe((status, error) {
          switch (status) {
            case RealtimeSubscribeStatus.channelError:
              log.warning("Broadcast channel error: $error");
              _startSync();
              break;
            case RealtimeSubscribeStatus.timedOut:
              log.warning("Broadcast channel timed out");
              _startSync();
              break;
            case RealtimeSubscribeStatus.closed:
              log.info("Broadcast channel closed");
              break;
            case RealtimeSubscribeStatus.subscribed:
              break;
          }
        });
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
    _unsubscribeFromRealtime();
    await _waitForNetworkConnectivity();
    await _syncAll();
    _subscribedToRealtime();
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
  int get schemaVersion => 79;

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
    _unsubscribeFromRealtime();
    await super.close();
  }

  void _unsubscribeFromRealtime() {
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = null;
  }
}
