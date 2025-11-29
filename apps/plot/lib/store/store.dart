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
import 'package:equatable/equatable.dart';
import 'package:rrule/rrule.dart';
import 'package:synchronized/synchronized.dart';
import 'package:rxdart/rxdart.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/async.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/twist_api.dart';
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
part 'activity_link.dart';
part 'activity.dart';
part 'activity_exception.dart';
part 'activity_tags.dart';
part 'activity_fts.dart';
part 'session.dart';
part 'tag.dart';

part 'store.g.dart';

mixin SyncableTable on Table {
  DateTimeColumn get updatedAt => dateTime()
      .withDefault(currentDateAndTime)
      .map(const LocalDateTimeConverter())();
  // >= 2 indicates pending sync; use bitmask for multiple states
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
  DateTimeColumn get archivedAt =>
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
      DateTimeRange? range,
      bool more,
    )
  >
  get({DateTimeRange? range, DateTime? updatedSince}) async {
    var query = select();
    query = filterRange(query, range);
    if (updatedSince != null) {
      query = query.gt("updated_at", updatedSince);
    }
    query = filter(query);
    PostgrestTransformBuilder<PostgrestList> query2 = sort(query);
    if (limit != null) {
      query2 = query2.limit(limit!);
    }
    final rows = await query2;
    DateTimeRange? returnRange;
    if (range != null) {
      returnRange = range;
    } else if (rows.isNotEmpty) {
      final firstTime = DateTime.parse(rows.first[order] as String);
      final lastTime = DateTime.parse(rows.last[order] as String);
      // For descending order, first row is newest, last row is oldest
      // DateTimeRange expects start <= end, so we need to swap for descending
      final start = ascending ? firstTime : lastTime;
      final end = ascending ? lastTime : firstTime;
      returnRange = DateTimeRange(start, end);
    }
    DateTime? lastUpdated;
    if (rows.isNotEmpty) {
      lastUpdated = rows
          .map((row) {
            return DateTime.parse(row['updated_at'] as String);
          })
          .reduce((value, last) => value.isAfter(last) ? value : last);
    }
    final more = limit != null && rows.length >= limit!;
    return (rows, lastUpdated, returnRange, more);
  }

  PostgrestFilterBuilder<PostgrestList> select() {
    return Base.client.from(table).select();
  }

  PostgrestFilterBuilder<T2> filterRange<T2>(
    PostgrestFilterBuilder<T2> query,
    DateTimeRange? range,
  ) {
    if (range == null) return query;

    DateTime? from = range.start;
    DateTime? to = range.end;

    if (!ascending) {
      final tmp = from;
      from = to;
      to = tmp;
    }
    if (from != null) {
      query = query.gte(order, from.toIso8601String());
    }
    if (to != null) {
      query = query.lte(order, to.toIso8601String());
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
    ActivityFts,
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
    final Random random = Random();
    _clientId ??= random.nextInt(2147483647); // Max int value
    return _clientId!;
  }

  // Lock to prevent concurrent Store.start() calls
  static final Lock _startLock = Lock();
  // Track the current user to avoid unnecessary Store recreation
  static String? _currentUserId;

  static Future<void> stop() async {
    if (Injector.appInstance.exists<Store>()) {
      await get.close();
    }
    Injector.appInstance.removeByKey<Store>();
    _currentUserId = null;
  }

  static Future<void> start(User user) async {
    return _startLock.synchronized(() async {
      driftRuntimeOptions.defaultSerializer = const CustomSerializer();

      // Skip if already initialized for this user
      if (Injector.appInstance.exists<Store>() && _currentUserId == user.id) {
        return;
      }

      // Update current user ID
      _currentUserId = user.id;

      // Close existing store if it exists
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
        await inst._waitForNetworkConnectivity();
        await inst._startSync();
        assert(await Priority.hasDefault(), "No default priority");
      }
    });
  }

  BroadcastClient? _broadcastClient;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;
  bool _isOnline = false;

  Future<DATA> add<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Insertable<DATA> data,
  ) async {
    try {
      Insertable<DATA> finalData = data;

      // Auto-set pending to 2 if it's absent or null
      try {
        final dynamic companion = data;
        final pendingValue = companion.pending;

        if (pendingValue is Value) {
          // If pending is absent or explicitly null, set it to 2
          if (!pendingValue.present || pendingValue.value == null) {
            finalData = companion.copyWith(pending: const Value(2)) as Insertable<DATA>;
          }
        }
      } catch (_) {
        // If the companion doesn't have a pending field, that's fine
      }

      return await Store.get
          .into(table)
          .insertReturning(finalData, onConflict: DoUpdate((old) => finalData));
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
      // Auto-set pending to 2 for any items where it's absent or null
      final processedData = data.map((item) {
        try {
          final dynamic companion = item;
          final pendingValue = companion.pending;

          if (pendingValue is Value) {
            // If pending is absent or explicitly null, set it to 2
            if (!pendingValue.present || pendingValue.value == null) {
              return companion.copyWith(pending: const Value(2)) as Insertable<DATA>;
            }
          }
        } catch (_) {
          // If the companion doesn't have a pending field, that's fine
        }
        return item;
      }).toList();

      await batch((batch) {
        batch.insertAllOnConflictUpdate(table, processedData);
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
    log.fine("Saving to ${table.actualTableName}:", data);
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
  /// - `(DateTime?, DateTime?)` tuple representing the range that was pulled:
  ///   - For descending tables: `(oldest_value, null)` representing "from oldest to now"
  ///   - For ascending tables: `(null, newest_value)` representing "from beginning to newest"
  ///
  /// The returned range can be used to synchronize related tables to ensure they
  /// cover the exact same data range.
  Future<(DateTime?, DateTime?)?>
  pull<TABLE extends SyncableTable, DATA extends DataClass>(
    PullType type,
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    (DateTime?, DateTime?)? range,
  }) async {
    log.fine("pull($type, ${baseTable.table}, range: $range)");

    // PullType.updates doesn't support range parameter
    if (type == PullType.updates && range != null) {
      throw ArgumentError('PullType.updates does not support range parameter');
    }

    final paged =
        [PullType.initial, PullType.more].contains(type) && range == null;
    if (paged && !hasMore(baseTable)) {
      return null;
    }
    final entity = baseTable.fullName;
    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();
    if (type == PullType.initial && syncState != null) {
      return null;
    }
    if (type == PullType.updates && syncState?.pulledAt == null) {
      return null;
    }

    // Adjust range to exclude already-synced data
    if (range != null && syncState?.last != null) {
      final (rangeFrom, rangeTo) = range;
      final lastSyncedMicros = syncState!.last!;
      final lastSynced = DateTime.fromMicrosecondsSinceEpoch(
        lastSyncedMicros,
        isUtc: true,
      );

      if (baseTable.ascending) {
        // For ascending order, synced range is (-∞, last]
        // Check if entire range is already synced
        if (rangeTo != null && !rangeTo.isAfter(lastSynced)) {
          log.fine(
            "Range ($rangeFrom, $rangeTo) is already synced (last: $lastSynced), skipping pull",
          );
          return null;
        }
        // Adjust rangeFrom to exclude overlap - add 1 microsecond to avoid duplicate
        range = (lastSynced.add(const Duration(microseconds: 1)), rangeTo);
      } else {
        // For descending order, synced range is [last, ∞)
        // Check if entire range is already synced
        if (rangeFrom != null && !rangeFrom.isBefore(lastSynced)) {
          log.fine(
            "Range ($rangeFrom, $rangeTo) is already synced (last: $lastSynced), skipping pull",
          );
          return null;
        }
        // Adjust rangeTo to exclude overlap - subtract 1 microsecond to avoid duplicate
        range = (
          rangeFrom,
          lastSynced.subtract(const Duration(microseconds: 1)),
        );
      }

      // After adjustment, check if range is still valid
      final (adjustedFrom, adjustedTo) = range;
      if (adjustedFrom != null &&
          adjustedTo != null &&
          !adjustedFrom.isBefore(adjustedTo)) {
        log.fine(
          "Adjusted range ($adjustedFrom, $adjustedTo) is empty, skipping pull",
        );
        return null;
      }
    }

    // For PullType.all: pull all rows on first pull (syncState?.pulledAt == null),
    // then only pull updates on subsequent pulls (syncState?.pulledAt != null)
    final pulledAtMicros =
        (type == PullType.updates ||
            (type == PullType.all && syncState?.pulledAt != null))
        ? syncState?.pulledAt
        : null;
    // Convert microseconds to DateTime for baseTable.get()
    final updatedSince = pulledAtMicros != null
        ? DateTime.fromMicrosecondsSinceEpoch(pulledAtMicros, isUtc: true)
        : null;

    // For PullType.updates, loop until all updates are fetched
    var totalRows = 0;
    var currentLast = syncState?.last != null
        ? DateTime.fromMicrosecondsSinceEpoch(
            syncState!.last!,
            isUtc: true,
          ).toString()
        : null;
    var more = false;
    DateTime? lastUpdated;
    var upsertedInLoop = false;

    do {
      DateTimeRange? requestRange;
      if (range != null) {
        requestRange = DateTimeRange(range.$1, range.$2);
      } else if (currentLast != null) {
        final currentLastDateTime = DateTime.parse(currentLast);
        final useAsFrom =
            (baseTable.ascending && type == PullType.more) ||
            (!baseTable.ascending && type == PullType.updates);
        final useAsTo =
            (baseTable.ascending && type == PullType.updates) ||
            (!baseTable.ascending && type == PullType.more);

        if (useAsFrom) {
          requestRange = DateTimeRange(currentLastDateTime, null);
        } else if (useAsTo) {
          requestRange = DateTimeRange(null, currentLastDateTime);
        }
      }

      log.fine("Requesting range $requestRange");
      var (baseRows, batchLastUpdated, newRange, batchMore) = (await baseTable
          .get(range: requestRange, updatedSince: updatedSince));
      final from = newRange?.start?.toString();
      final to = newRange?.end?.toString();
      more = batchMore;
      if (batchLastUpdated != null) {
        lastUpdated = batchLastUpdated;
      }

      if (baseRows.isNotEmpty) {
        log.info("Pulled ${baseRows.length} rows from ${baseTable.table}");
      } else {
        log.fine(
          "Pulling ${baseRows.length} rows from ${baseTable.table} (type: $type, from: $from, to: $to, more: $more)",
        );
      }
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

      // Only set _noMore for range-extending pulls (initial/more), not for updates
      if (!more && type != PullType.updates) {
        _noMore.add(entity);
        log.fine("No more data for entity $entity (type: $type)");
      }

      if (lastUpdated != null) {
        // For PullType.updates: only update pulledAt (last update timestamp)
        // For PullType.initial/more: update both pulledAt and last (range boundary)
        final lastMicros = lastUpdated.toUtc().microsecondsSinceEpoch;

        if (type == PullType.updates) {
          await into(syncStates).insert(
            SyncStatesCompanion.insert(
              entity: entity,
              pulledAt: Value(lastMicros),
              // Don't update 'last' for updates - it tracks range boundary, not update timestamp
            ),
            onConflict: DoUpdate(
              (old) => SyncStatesCompanion(
                entity: Value(entity),
                pulledAt: Value(lastMicros),
                // Preserve existing 'last' value
              ),
            ),
          );
        } else {
          // For initial/more: update both pulledAt and last
          await into(syncStates).insert(
            SyncStatesCompanion.insert(
              entity: entity,
              pulledAt: Value(lastMicros),
              last: Value(lastMicros),
            ),
            onConflict: DoUpdate(
              (old) => SyncStatesCompanion(
                entity: Value(entity),
                pulledAt: Value(lastMicros),
                last: Value(lastMicros),
              ),
            ),
          );
        }
        upsertedInLoop = true;
      }

      // Update currentLast for next iteration
      if (type == PullType.updates && more && to != null) {
        currentLast = to;
      }
    } while (type == PullType.updates && more);

    if (totalRows > 0) {
      log.info("Synced ${baseTable.name}: $totalRows rows");
    }

    // Skip final upsert if we already upserted in the loop
    if (!upsertedInLoop && lastUpdated != null) {
      // Convert DateTime to microseconds since epoch for storage
      final pulledAtMicrosToStore = lastUpdated.toUtc().microsecondsSinceEpoch;

      if (type == PullType.updates) {
        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            pulledAt: Value(pulledAtMicrosToStore),
            // Don't update 'last' for updates
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entity),
              pulledAt: Value(pulledAtMicrosToStore),
              // Preserve existing 'last' value
            ),
          ),
        );
      } else {
        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            pulledAt: Value(pulledAtMicrosToStore),
            last: Value(pulledAtMicrosToStore),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entity),
              pulledAt: Value(pulledAtMicrosToStore),
              last: Value(pulledAtMicrosToStore),
            ),
          ),
        );
      }
    }

    // Return the range that was pulled
    // For descending tables, syncState.last is the oldest boundary
    // Return (oldest, null) to represent the range from oldest onwards
    final finalSyncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();

    if (finalSyncState?.last != null) {
      final lastDateTime = DateTime.fromMicrosecondsSinceEpoch(
        finalSyncState!.last!,
        isUtc: true,
      );
      return (lastDateTime, null);
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
    log.fine("Syncing $table");
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
    await _broadcastClient!.connect(_handleBroadcastMessage, clientId);
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
      log.fine("Sync already in progress, skipping");
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

  void _setupConnectivityListener() async {
    try {
      // Cancel any existing subscription
      _connectivitySubscription?.cancel();

      // Check initial connectivity state
      final initialResults = await Connectivity().checkConnectivity();
      _isOnline = initialResults.any(
        (result) => result != ConnectivityResult.none,
      );
      if (_isOnline) {
        await _startSync();
      }

      // Monitor connectivity changes throughout app lifecycle
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
        results,
      ) async {
        final wasOnline = _isOnline;
        final isOnline = results.any(
          (result) => result != ConnectivityResult.none,
        );
        _isOnline = isOnline;

        // Only trigger sync when transitioning from offline to online
        if (!wasOnline && isOnline && !_isSyncing) {
          log.info("Connectivity restored, attempting to sync");
          // Attempt sync when connectivity is restored (fire and forget)
          _startSync().catchError((Object error, StackTrace stackTrace) {
            log.warning(
              "Connectivity-triggered sync failed",
              error,
              stackTrace,
            );
            return null;
          });
        }
      });
    } catch (e, t) {
      log.warning("Error setting up connectivity listener", e, t);
    }
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
  int get schemaVersion => 152;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await ActivityFts.createTable(m.database);
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // For schema version 141, completely rebuild the database
        // Drop views manually using raw SQL before dropping tables
        final db = m.database;
        for (final view in [
          'priority_children',
          'priority_ancestry',
          'latest_priorities',
        ]) {
          try {
            await db.customStatement('DROP VIEW IF EXISTS $view');
          } catch (e) {
            // View might not exist or might fail - ignore
          }
        }

        // Drop all entities
        for (final entity in allSchemaEntities) {
          try {
            await m.drop(entity);
          } catch (e) {
            // Ignore errors - entity might not exist
          }
        }

        await m.createAll();
        await ActivityFts.createTable(db);
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
