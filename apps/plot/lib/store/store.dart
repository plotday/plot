import 'dart:async';
import 'dart:math';

import 'dart:convert';
import 'package:flutter/widgets.dart' show IconData;
import 'package:logging/logging.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:collection/collection.dart';
import 'package:injector/injector.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
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
import 'package:plot/util/value.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/broadcast.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/base.dart';
import 'enums.dart';
import 'types.dart';
import 'logging.dart';
import 'sync_entity.dart';

export 'package:plot/util/value.dart';
export 'package:plot/util/time.dart';
export 'package:plot/util/uuid.dart';
export 'package:plot/util/order.dart';
export 'package:plot/util/path.dart';
export 'package:plot/base.dart';
export 'schedule.dart';
export 'enums.dart';

part 'sync.dart';
part 'sync_orchestrator.dart';
part 'actor.dart';
part 'priority.dart';
part 'priority_twist.dart';
part 'link.dart';
part 'activity.dart';
part 'note.dart';
part 'activity_exception.dart';
part 'activity_tags.dart';
part 'note_tags.dart';
part 'activity_fts.dart';
part 'note_fts.dart';
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

    // Execute query with auth error detection
    late final List<Map<String, dynamic>> rows;
    try {
      rows = await query2;
    } catch (e) {
      if (Store._isAuthError(e)) {
        await Store._handleAuthError();
      }
      rethrow;
    }

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

  /// Applies created_at boundary filters for pagination (PullType.more).
  /// Uses exclusive bounds (gt/lt) to avoid fetching duplicate rows.
  ///
  /// For descending order (newest first):
  /// - range.start: lower bound (older items) → created_at > start
  /// - range.end: upper bound (newer items) → created_at < end
  ///
  /// For ascending order (oldest first):
  /// - range.start: lower bound (older items) → created_at > start
  /// - range.end: upper bound (newer items) → created_at < end
  PostgrestFilterBuilder<T2> filterRange<T2>(
    PostgrestFilterBuilder<T2> query,
    DateTimeRange? range,
  ) {
    if (range == null) return query;

    final from = range.start;
    final to = range.end;

    // Apply exclusive bounds to avoid duplicates
    if (from != null) {
      query = query.gt(order, from.toIso8601String());
    }
    if (to != null) {
      query = query.lt(order, to.toIso8601String());
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

    try {
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
    } catch (e) {
      if (Store._isAuthError(e)) {
        await Store._handleAuthError();
      }
      rethrow;
    }
  }
}

@DriftDatabase(
  tables: [
    SyncStates,
    Actors,
    Priorities,
    PriorityTwists,
    Activities,
    Notes,
    ActivityFts,
    NoteFts,
    ActivityExceptions,
    ActivityTags,
    NoteTags,
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
      // Get reference before removing from injector
      final store = get;
      // Remove singleton reference BEFORE closing to prevent access during transition
      Injector.appInstance.removeByKey<Store>();
      await store.close();
    }
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

        // If no default priority exists after sync, sign out the user
        if (!await Priority.hasDefault()) {
          log.warning("No default priority after sync - signing out user");
          try {
            await Base.client.auth.signOut();
          } catch (e, stackTrace) {
            log.warning("Error during no-priority sign-out", e, stackTrace);
          }
          return; // Exit early since sign-out will trigger UserBloc state change
        }
      }
    });
  }

  /// Checks if an error is an authentication failure (401 or JWT expired)
  /// Note: 403 (Forbidden) means user is authenticated but not authorized,
  /// so it should NOT trigger sign-out
  static bool _isAuthError(dynamic error) {
    // Check for PostgrestException (from Supabase database operations)
    if (error is PostgrestException) {
      return error.code == 'PGRST301' || // JWT expired
          error.code == 'PGRST302' || // JWT invalid
          error.details?.toString().toLowerCase().contains('unauthorized') ==
              true;
    }

    // Check for generic exceptions with 401 status code (not 403)
    if (error is Exception) {
      final message = error.toString().toLowerCase();
      return message.contains('401') || message.contains('unauthorized');
    }

    return false;
  }

  /// Handles authentication errors by signing out the user
  /// This triggers the auth state change listener which will update UserBloc
  static Future<void> _handleAuthError() async {
    log.warning("Authentication failure detected - signing out user");
    try {
      await Base.client.auth.signOut();
    } catch (e, stackTrace) {
      log.warning("Error during auth failure sign-out", e, stackTrace);
    }
  }

  BroadcastClient? _broadcastClient;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;
  bool _isOnline = false;

  // Adaptive batch debouncer for sync requests per table
  late final BatchDebouncer<String> _syncDebouncer = BatchDebouncer(
    maxInitialMs: 200,
    maxSubsequentMs: 500,
    waitMs: 250,
    onBatch: _handleTableSync,
  );

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
            finalData =
                companion.copyWith(pending: const Value(2)) as Insertable<DATA>;
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
              return companion.copyWith(pending: const Value(2))
                  as Insertable<DATA>;
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
                  "Error pushing ${baseTable.toBase(data)} to ${baseTable.writeTable ?? baseTable.table}",
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
  /// ## Sync State Management
  /// The sync state tracks two orthogonal concerns:
  /// - `pulledAt`: Timestamp of last update check (microseconds since epoch)
  ///   - Used by: PullType.initial, PullType.updates
  ///   - Purpose: Track when we last checked for new/updated items
  /// - `last`: Pagination boundary timestamp (microseconds since epoch, based on created_at)
  ///   - Used by: PullType.more
  ///   - Purpose: Track the oldest/newest item we've synced for pagination
  ///
  /// ## Pull Types
  /// - [PullType.initial]: First-time setup pull
  ///   - Behavior: Fetches initial data (respects baseTable.limit)
  ///   - Updates: Sets pulledAt (to max updated_at or now if no rows)
  ///   - Ignores: last (doesn't read or write)
  ///   - Skip: If pulledAt already exists
  ///
  /// - [PullType.more]: Pagination pull (typically for activities)
  ///   - Behavior: Fetches next page using created_at boundaries
  ///   - Updates: Sets last (to oldest/newest created_at depending on sort order)
  ///   - Ignores: pulledAt (doesn't read or write)
  ///   - For descending: Fetches items older than current last
  ///   - For ascending: Fetches items newer than current last
  ///
  /// - [PullType.updates]: Incremental update pull
  ///   - Behavior: Fetches items with updated_at > pulledAt
  ///   - Updates: Sets pulledAt (to max updated_at)
  ///   - Ignores: last (doesn't read or write)
  ///   - Loops internally until all updates are fetched
  ///
  /// ## Parameters
  /// - [range]: Optional date range tuple (start, end)
  ///   - For PullType.more: Represents the calendar date range to filter by
  ///   - For PullType.updates: Not supported (throws ArgumentError)
  ///
  /// ## Returns
  /// - `null`: Nothing was pulled (skipped, early exit, or no data)
  /// - `(DateTime?, DateTime?)`: Range that was pulled (based on created_at)
  ///   - For descending: `(oldest, null)` = "from oldest onwards"
  ///   - For ascending: `(null, newest)` = "from beginning to newest"
  /// Pulls initial data or updates for an entity.
  ///
  /// When [initial] is true, performs an initial pull (fetches first page).
  /// When [initial] is false, fetches updates since last pull (incremental sync).
  ///
  /// Optional [range] parameter filters by date range (for calendar filtering).
  /// Note: range is not supported for update pulls (initial=false).
  ///
  /// Updates only the pulledAt timestamp in sync state.
  /// Use [pullMore] for pagination.
  Future<(DateTime?, DateTime?)?>
  pull<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    bool initial = false,
    (DateTime?, DateTime?)? range,
  }) async {
    log.fine("pull(initial: $initial, ${baseTable.table}, range: $range)");

    // Update pulls don't support range parameter
    if (!initial && range != null) {
      throw ArgumentError('Update pulls do not support range parameter');
    }

    final entity = baseTable.fullName;
    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();

    // Initial pull: Skip if pulledAt already exists
    if (initial && syncState?.pulledAt != null) {
      return null;
    }

    // Update pull: Skip if pulledAt doesn't exist (must do initial first)
    if (!initial && syncState?.pulledAt == null) {
      return null;
    }

    // Fetch items with updated_at > pulledAt (for updates only)
    final pulledAtMicros = !initial ? syncState?.pulledAt : null;
    final updatedSince = pulledAtMicros != null
        ? DateTime.fromMicrosecondsSinceEpoch(pulledAtMicros, isUtc: true)
        : null;

    // For updates, loop until all updates are fetched
    var totalRows = 0;
    var more = false;
    DateTime? lastUpdated;
    var upsertedInLoop = false;

    do {
      DateTimeRange? requestRange;
      if (range != null) {
        requestRange = DateTimeRange(range.$1, range.$2);
      }
      // For updates, don't set requestRange - only use updatedSince filter

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
          "Pulling ${baseRows.length} rows from ${baseTable.table} (initial: $initial, from: $from, to: $to, more: $more)",
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

      // Set _noMore for range-extending pulls (initial only, not for updates)
      if (!more && initial) {
        _noMore.add(entity);
        log.fine("No more data for entity $entity (initial: $initial)");
      }

      if (lastUpdated != null) {
        final lastUpdatedMicros = lastUpdated.toUtc().microsecondsSinceEpoch;

        // Update pulledAt only (preserve 'last' for pagination)
        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            pulledAt: Value(lastUpdatedMicros),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entity),
              pulledAt: Value(lastUpdatedMicros),
              // Preserve existing 'last' value
            ),
          ),
        );
        upsertedInLoop = true;
      }
    } while (!initial && more);

    if (totalRows > 0) {
      log.info("Synced ${baseTable.name}: $totalRows rows");
    }

    // Skip final upsert if we already upserted in the loop
    if (!upsertedInLoop) {
      // Set pulledAt for initial pull even if no rows (marks entity as initialized)
      if (initial) {
        final nowMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            pulledAt: Value(nowMicros),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entity),
              pulledAt: Value(nowMicros),
              // Preserve existing 'last' value
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

  /// Pulls the next page of data for pagination.
  ///
  /// Updates only the 'last' timestamp in sync state (pagination boundary).
  /// Supports optional [range] parameter for calendar date filtering.
  Future<(DateTime?, DateTime?)?>
  pullMore<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    (DateTime?, DateTime?)? range,
  }) async {
    log.fine("pullMore(${baseTable.table}, range: $range)");

    final entity = baseTable.fullName;
    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();

    // Check if we have more data to fetch (for paged pulls without range)
    final paged = range == null;
    if (paged && !hasMore(baseTable)) {
      return null;
    }

    // Adjust range to exclude already-synced data (pagination)
    // For descending order (like activities): synced range is [last, +∞)
    // For ascending order: synced range is (-∞, last]
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
        // Adjust rangeFrom to exclude overlap - use exclusive bound (gt not gte)
        range = (lastSynced, rangeTo);
      } else {
        // For descending order, synced range is [last, +∞)
        // Check if entire range is already synced
        if (rangeFrom != null && !rangeFrom.isBefore(lastSynced)) {
          log.fine(
            "Range ($rangeFrom, $rangeTo) is already synced (last: $lastSynced), skipping pull",
          );
          return null;
        }
        // Adjust rangeTo to exclude overlap - use exclusive bound (lt not lte)
        range = (rangeFrom, lastSynced);
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

    var totalRows = 0;
    var more = false;
    DateTime? lastUpdated;

    DateTimeRange? requestRange;
    if (range != null) {
      requestRange = DateTimeRange(range.$1, range.$2);
    } else if (syncState?.last != null) {
      // For pagination, use created_at range to fetch older data
      final currentLast = DateTime.fromMicrosecondsSinceEpoch(
        syncState!.last!,
        isUtc: true,
      );
      if (baseTable.ascending) {
        // Ascending: fetch data after currentLast
        requestRange = DateTimeRange(currentLast, null);
      } else {
        // Descending: fetch data before currentLast
        requestRange = DateTimeRange(null, currentLast);
      }
    }

    log.fine("Requesting range $requestRange");
    var (baseRows, batchLastUpdated, newRange, batchMore) = (await baseTable
        .get(range: requestRange, updatedSince: null));
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
        "Pulling ${baseRows.length} rows from ${baseTable.table} (from: $from, to: $to, more: $more)",
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

    // Set _noMore for range-extending pulls
    if (!more) {
      _noMore.add(entity);
      log.fine("No more data for entity $entity");
    }

    if (lastUpdated != null) {
      // Update 'last' only (pagination boundary)
      // Use created_at of first row for the pagination boundary
      if (baseRows.isNotEmpty) {
        final firstRowCreatedAt = DateTime.parse(
          baseRows.first[baseTable.order] as String,
        );
        final createdAtMicros = firstRowCreatedAt
            .toUtc()
            .microsecondsSinceEpoch;

        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entity,
            last: Value(createdAtMicros),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entity),
              last: Value(createdAtMicros),
              // Preserve existing 'pulledAt' value
            ),
          ),
        );
      }
    }

    if (totalRows > 0) {
      log.info("Synced ${baseTable.name}: $totalRows rows");
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
      // Use orchestrator for dependency-aware sync
      // This pulls all entities (parents→children), then pushes all (children→parents)
      await SyncOrchestrator.instance.syncAll();
    } catch (e, stackTrace) {
      // Check if this is an auth error - if so, sign out
      if (_isAuthError(e)) {
        log.warning("Auth error during sync", e, stackTrace);
        await _handleAuthError();
        rethrow; // Stop sync on auth errors
      }
      // Network errors and other issues are logged but don't stop the app
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
        case 'priority_twist':
          if (!await PriorityTwist.push()) {
            log.warning("PriorityTwist push failed during table sync");
          }
          await PriorityTwist.pullInitial();
          await PriorityTwist.pullUpdates();
          break;
        case 'activity':
        case 'activity_read':
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
        case 'note':
          if (!await Note.push()) {
            log.warning("Note push failed during table sync");
          }
          await Note.pullInitial();
          await Note.pullUpdates();
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

    _syncDebouncer(table);
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
  int get schemaVersion => 180;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await ActivityFts.createTable(m.database);
        await NoteFts.createTable(m.database);

        // Create unique partial indexes for draft constraints
        await m.database.customStatement(
          'CREATE UNIQUE INDEX idx_activity_unique_draft_per_priority '
          'ON activities (priority_id) '
          'WHERE draft = 1 AND archived_at IS NULL',
        );
        await m.database.customStatement(
          'CREATE UNIQUE INDEX idx_note_unique_draft_per_activity '
          'ON notes (activity_id) '
          'WHERE draft = 1 AND archived_at IS NULL',
        );
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
        await NoteFts.createTable(db);

        // Create unique partial indexes for draft constraints
        await db.customStatement(
          'CREATE UNIQUE INDEX idx_activity_unique_draft_per_priority '
          'ON activities (priority_id) '
          'WHERE draft = 1 AND archived_at IS NULL',
        );
        await db.customStatement(
          'CREATE UNIQUE INDEX idx_note_unique_draft_per_activity '
          'ON notes (activity_id) '
          'WHERE draft = 1 AND archived_at IS NULL',
        );
      },
    );
  }

  @override
  Future<void> close() async {
    _unsubscribeFromUpdates();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    // Cancel all pending debounce timers
    _syncDebouncer.dispose();

    await super.close();
  }

  void _unsubscribeFromUpdates() {
    _broadcastClient?.disconnect();
    _broadcastClient = null;
  }
}
