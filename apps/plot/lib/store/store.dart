import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'dart:convert';
import 'package:flutter/widgets.dart' show IconData;
import 'package:logging/logging.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:collection/collection.dart';
import 'package:injector/injector.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:equatable/equatable.dart';
import 'package:rrule/rrule.dart';
import 'package:synchronized/synchronized.dart';
import 'package:rxdart/rxdart.dart';
import 'package:change_case/change_case.dart';

import 'package:plot/util/uuid.dart';
import 'package:plot/util/time.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/util/path.dart';
import 'package:plot/util/order.dart';
import 'package:plot/util/list.dart';
import 'package:plot/util/async.dart';
import 'package:plot/util/value.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/broadcast.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/base.dart';
import 'package:plot/cli_args.dart';
import 'package:plot/analytics/tracker.dart';
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
part 'priority_user.dart';
part 'priority_member.dart';
part 'priority_actor.dart';
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
part 'user_settings.dart';

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
    required this.syncEndpoint,
    this.order = 'created_at',
    this.ascending = true,
    this.supportsArchiving = true,
    String? name,
    this.filterName,
    this.limit,
    this.cursorColumn = 'id',
  }) : name = name ?? "${table}s";

  final String table;

  /// The sync API endpoint path (e.g., 'activities', 'notes')
  final String syncEndpoint;

  final String name;
  final String? filterName;
  String get fullName => "$name${filterName == null ? "" : ":$filterName"}";
  final String order;
  final bool ascending;
  final int? limit;
  final bool supportsArchiving;

  /// Column to use for composite cursor pagination (default: 'id')
  final String cursorColumn;

  Map<String, dynamic> toBase(DataClass row) {
    final json = row.toJson();
    json['updated_by'] = Store.clientId;
    json.remove('pending');
    return json;
  }

  Insertable<DataClass> fromBase(Map<String, dynamic> json);

  /// Process rows pulled from server before inserting to local DB.
  /// Subclasses can override to preserve local pending state.
  /// Default implementation returns rows unchanged.
  Future<List<Insertable<DataClass>>> processPulledRows(
    Store store,
    Iterable<Insertable<DataClass>> rows,
  ) async {
    return rows.toList();
  }

  /// Build query params for the sync API call.
  /// Subclasses override to add entity-specific params (e.g., priority_path).
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = <String, String>{};
    if (updatedSince != null) {
      params['updated_since'] = updatedSince.toIso8601String();
    }
    if (lastId != null) params['cursor_id'] = lastId;
    if (initial) params['initial'] = 'true';
    if (supportsArchiving && updatedSince == null) {
      params['archived'] = archived.toString();
    }
    if (limit != null) params['limit'] = limit.toString();
    return params;
  }

  /// Build range query params for calendar/pagination filtering.
  /// Override in subclasses for entity-specific range filtering (e.g., calendar overlap).
  /// Default returns empty map (no range filtering).
  Map<String, String> buildRangeParams(DateTimeRange range) {
    return {};
  }

  Future<
    (
      Iterable<Map<String, dynamic>> rows,
      DateTime? lastUpdated,
      String? lastId,
      DateTimeRange? range,
      bool more,
    )
  >
  get({
    DateTimeRange? range,
    DateTime? updatedSince,
    String? lastId,
    bool initial = false,
    bool archived = false,
  }) async {
    final params = buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
      initial: initial,
      archived: archived,
    );

    // For non-update pulls, add sort params so server sorts by entity's order column
    if (updatedSince == null) {
      params['sort_by'] = order;
      params['sort_dir'] = ascending ? 'asc' : 'desc';
    }

    // Add range params
    if (range != null) {
      params.addAll(buildRangeParams(range));
    }

    final queryString = params.entries
        .where((e) => e.value.isNotEmpty)
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');

    // Execute query with auth error detection
    late final List<Map<String, dynamic>> rows;
    try {
      final result = await api.get<List<dynamic>>(
        '/sync/$syncEndpoint${queryString.isNotEmpty ? '?$queryString' : ''}',
      );
      rows = result.cast<Map<String, dynamic>>();
    } catch (e) {
      if (Store._isAuthError(e)) {
        Store._handleAuthError();
      } else if (Store._isRlsViolation(e)) {
        // Log RLS violations for debugging without signing out
        log.warning(
          "RLS policy violation - this indicates an app bug where code is accessing restricted data",
          e,
        );

        // Report RLS violations to PostHog (indicates app bugs)
        Tracker.trackError(
          'database',
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: StackTrace.current.toString(),
          context: 'sync_rls_violation_read',
        );
      }
      rethrow;
    }

    DateTimeRange? returnRange;
    // returnRange is only meaningful for pullTo() (range-based sync).
    // For update pulls (updatedSince != null), sort is by updated_at not the
    // primary order column, so created_at range would be meaningless.
    if (updatedSince != null) {
      // Skip range computation for update pulls
    } else if (range != null) {
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
    String? returnLastId;
    if (rows.isNotEmpty) {
      if (updatedSince != null) {
        // With ASC sort, last row has the max updated_at
        lastUpdated = DateTime.parse(rows.last['updated_at'] as String);
      } else {
        lastUpdated = rows
            .map((row) {
              return DateTime.parse(row['updated_at'] as String);
            })
            .reduce((value, last) => value.isAfter(last) ? value : last);
      }
      // Extract last cursor value for composite cursor pagination
      returnLastId = rows.last[cursorColumn] as String?;
    }
    final more = limit != null && rows.length >= limit!;
    return (rows, lastUpdated, returnLastId, returnRange, more);
  }

  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;

    try {
      for (final row in rows) {
        await api.post<Map<String, dynamic>>('/sync/$syncEndpoint', body: row);
      }
    } catch (e) {
      if (Store._isAuthError(e)) {
        Store._handleAuthError();
      } else if (Store._isRlsViolation(e)) {
        // Log RLS violations for debugging without signing out
        log.warning(
          "RLS policy violation during write - this indicates an app bug where code is trying to write restricted data",
          e,
        );

        // Report RLS violations to PostHog (indicates app bugs)
        Tracker.trackError(
          'database',
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: StackTrace.current.toString(),
          context: 'sync_rls_violation_write',
        );
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
    PriorityUsers,
    PriorityMembers,
    PriorityActors,
    PriorityTwists,
    Activities,
    Notes,
    ActivityFts,
    NoteFts,
    ActivityExceptions,
    ActivityTags,
    NoteTags,
    Sessions,
    UserSettings,
  ],
  include: {'priority.drift'},
)
class Store extends _$Store {
  static Store get get => Injector.appInstance.get<Store>();

  // Track ongoing push operations per table to prevent concurrent pushes
  static final Map<String, Completer<bool>> _pushCompleters = {};

  // Client ID for tracking updates to prevent sync loops.
  // Positive values indicate app client updates.
  // Negative values indicate twist/API updates (set by truncateUuidForUpdatedBy).
  static int? _clientId;
  static int get clientId {
    final Random random = Random();
    _clientId ??= random.nextInt(2147483647); // Max int value (always positive)
    return _clientId!;
  }

  // Lock to prevent concurrent Store.start() calls
  static final Lock _startLock = Lock();
  // Track the current user to avoid unnecessary Store recreation
  static String? _currentUserId;
  static String? get currentUserId => _currentUserId;

  static Future<void> stop() async {
    _authRetryTimer?.cancel();
    _authRetryTimer = null;
    _authFailureCount = 0;
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

      var inst = Store._(user);
      Injector.appInstance.registerSingleton<Store>(() => inst, override: true);

      bool hasDefault;
      try {
        hasDefault = await Priority.hasDefault();
      } catch (e, stackTrace) {
        log.warning('Priority.hasDefault() failed, attempting schema rebuild', e, stackTrace);
        Tracker.trackError(
          'database',
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: stackTrace.toString(),
          context: 'store_start_schema_error',
        );

        // Try rebuilding schema in place
        try {
          await _dropAllUserObjects(inst);
          await Migrator(inst).createAll();
          await ActivityFts.createTable(inst);
          await NoteFts.createTable(inst);
          hasDefault = false; // Schema was rebuilt, no data
        } catch (rebuildError, rebuildTrace) {
          log.warning('In-place rebuild failed, recreating Store', rebuildError, rebuildTrace);
          // Close broken store, create fresh one (triggers fresh beforeOpen)
          await inst.close();
          inst = Store._(user);
          Injector.appInstance.registerSingleton<Store>(() => inst, override: true);
          hasDefault = false;
        }
      }

      if (hasDefault) {
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
            await Base.signOut();
          } catch (e, stackTrace) {
            log.warning("Error during no-priority sign-out", e, stackTrace);
          }
          return; // Exit early since sign-out will trigger UserBloc state change
        }
      }
    });
  }

  /// Checks if an error is an authentication failure (JWT expired/invalid only)
  /// Note: 403 (Forbidden) means user is authenticated but not authorized,
  /// so it should NOT trigger sign-out. Similarly, RLS violations (code 42501)
  /// indicate authorization failures, not authentication failures.
  static bool _isAuthError(dynamic error) {
    // Check for ApiException with 401 status (Unauthorized)
    if (error is ApiException) {
      return error.statusCode == 401;
    }

    return false;
  }

  /// Checks if an error is a Row-Level Security (RLS) violation
  /// RLS violations (code 42501) indicate an app bug where the code is trying
  /// to access data it shouldn't. These should NOT trigger sign-out but should
  /// be logged so developers can identify and fix the app bug.
  static bool _isRlsViolation(dynamic error) {
    if (error is ApiException) {
      return error.statusCode == 403 || error.pgCode == '42501';
    }
    return false;
  }

  /// Checks if an error is a permanent data error that should not be retried
  /// These errors indicate invalid data that will never succeed on retry and
  /// should be reverted to the remote version instead.
  static bool _isPermanentError(dynamic error) {
    if (error is ApiException) {
      // 400 (Bad Request), 403 (Forbidden), 409 (Conflict), 422 (Unprocessable)
      // are permanent errors that won't succeed on retry.
      // Exclude 401 (auth), 408 (timeout), 429 (rate limit) which are transient.
      const permanentStatuses = {400, 403, 409, 422};
      return permanentStatuses.contains(error.statusCode);
    }
    return false;
  }

  /// Reverts a local row to its remote version after a permanent error
  /// If the row doesn't exist remotely, it's deleted locally
  Future<void>
  _revertToRemote<TABLE extends SyncableTable, DATA extends DataClass>(
    BaseTable baseTable,
    TableInfo<TABLE, DATA> table,
    Map<String, dynamic> localRow,
  ) async {
    final id = localRow['id'] as Object;

    try {
      // Fetch current remote version by ID via sync API
      final rows = await api.get<List<dynamic>>(
        '/sync/${baseTable.syncEndpoint}?id=${Uri.encodeQueryComponent(id.toString())}',
      );
      final response = rows.isEmpty
          ? null
          : (rows.first as Map<String, dynamic>);

      if (response == null) {
        // Row doesn't exist remotely - delete local copy
        log.warning(
          "Reverting local-only ${baseTable.table} row by deleting it: $localRow",
        );

        await customStatement(
          'DELETE FROM ${table.actualTableName} WHERE id = ?',
          [id],
        );
      } else {
        // Row exists remotely - revert to remote version
        log.warning(
          "Reverting local changes to remote version (ID: $id, table: ${baseTable.table})",
        );

        // Convert remote row to Insertable and clear pending
        final remoteData = baseTable.fromBase(response);

        // Update local database to match remote using batch insert
        await batch((batch) {
          batch.insertAllOnConflictUpdate(table, [remoteData]);
        });
      }
    } catch (e, trace) {
      log.severe(
        "Failed to revert row to remote version (ID: $id, table: ${baseTable.table})",
        e,
        trace,
      );
      // Don't rethrow - we tried our best
    }
  }

  static int _authFailureCount = 0;
  static Timer? _authRetryTimer;

  /// Auth errors during sync are treated as transient (like being offline).
  /// Schedule a retry with increasing backoff instead of signing out.
  static void _handleAuthError() {
    _authFailureCount++;
    final delaySec = min(30 * _authFailureCount, 300); // 30s, 60s, ... max 5min
    log.warning(
      "Auth error during sync (attempt $_authFailureCount), retrying in ${delaySec}s",
    );

    _authRetryTimer?.cancel();
    if (Injector.appInstance.exists<Store>()) {
      _authRetryTimer = Timer(Duration(seconds: delaySec), () {
        if (Injector.appInstance.exists<Store>()) {
          Store.get._startSync().catchError((Object e, StackTrace s) {
            log.warning("Auth retry sync failed", e, s);
          });
        }
      });
    }
  }

  /// Reset auth failure tracking after successful sync.
  static void _resetAuthFailures() {
    if (_authFailureCount > 0) {
      log.info("Sync recovered after $_authFailureCount auth failures");
    }
    _authFailureCount = 0;
    _authRetryTimer?.cancel();
    _authRetryTimer = null;
  }

  BroadcastClient? _broadcastClient;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isSyncing = false;
  bool _isOnline = false;
  bool _isBufferingBroadcasts = false;
  final _bufferedTables = <String>{};

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
    // Fire and forget push through orchestrator for dependency awareness
    final entity = SyncOrchestrator.getEntityByTableName(baseTable.table);
    if (entity != null) {
      SyncOrchestrator.instance.push(entity);
    } else {
      // Fallback to direct push for entities not in orchestrator
      push(table, baseTable);
    }
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
                if (Store._isAuthError(e)) {
                  Store._handleAuthError();
                  rethrow;
                } else if (Store._isPermanentError(e)) {
                  // Permanent error - revert local change to remote version
                  final errorMsg = e is ApiException
                      ? e.description
                      : 'Invalid local change';
                  log.warning(
                    "Permanent error during sync (${baseTable.table}): $errorMsg. Reverting row.",
                    e,
                    stackTrace,
                  );

                  // Revert to remote version
                  await _revertToRemote(
                    baseTable,
                    table,
                    baseTable.toBase(data),
                  );

                  // Don't set success = true (this wasn't a successful push)
                } else {
                  // Transient error - log and continue
                  log.warning(
                    "Error pushing ${baseTable.toBase(data)} to ${baseTable.syncEndpoint}",
                    e,
                    stackTrace,
                  );
                }
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
  }) async {
    final entity = baseTable.fullName;

    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();

    // Initial pull: Skip if pulledAt already exists
    if (initial && syncState?.pulledAt != null) {
      return null;
    }

    // Update pull: If we didn't do an initial, just mark now as pullAt
    // so we get updates from this point on.
    if (!initial && syncState?.pulledAt == null) {
      log.fine("No previous pulledAt for ${baseTable.table}, setting to now");
      // Update pulledAt (and firstPulledAt on initial pull)
      final lastUpdatedMicros = DateTime.now().microsecondsSinceEpoch;
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: entity,
          pulledAt: Value(lastUpdatedMicros),
          firstPulledAt: Value(lastUpdatedMicros),
        ),
        onConflict: DoUpdate(
          (old) => SyncStatesCompanion(
            entity: Value(entity),
            pulledAt: Value(lastUpdatedMicros),
            firstPulledAt: Value(lastUpdatedMicros),
            // Preserve existing 'last' and 'noMore' values
          ),
        ),
      );
      return null;
    }

    // Fetch items with updated_at > pulledAt (for updates only)
    final pulledAtMicros = !initial ? syncState?.pulledAt : null;
    var lastUpdated = pulledAtMicros != null
        ? DateTime.fromMicrosecondsSinceEpoch(pulledAtMicros, isUtc: true)
        : null;
    String? lastId;

    // For updates, loop until all updates are fetched
    var totalRows = 0;
    var more = false;

    do {
      var (
        baseRows,
        batchLastUpdated,
        batchLastId,
        newRange,
        batchMore,
      ) = (await baseTable.get(
        updatedSince: lastUpdated,
        lastId: lastId,
        initial: initial,
      ));
      final from = newRange?.start?.toString();
      final to = newRange?.end?.toString();
      more = batchMore && batchLastUpdated != null;
      if (batchLastUpdated != null) {
        lastUpdated = batchLastUpdated;
        lastId = batchLastId;
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

      // Allow base table to merge with local pending state
      final processedRows = await baseTable.processPulledRows(this, storeRows);

      await batch((batch) {
        // Use insertOrReplace mode to ensure null values are explicitly set.
        // - insertAllOnConflictUpdate uses toColumns(true) which treats null as
        //   "don't update this column" - causing unarchived items to stay archived
        // - insertOrReplace deletes and re-inserts the row, ensuring all columns
        //   including nulls are set correctly
        batch.insertAll(table, processedRows, mode: InsertMode.insertOrReplace);
      });

      totalRows += baseRows.length;
    } while (!initial && more);

    if (totalRows > 0) {
      log.info("Synced ${baseTable.name}: $totalRows rows");
    }

    // Update pulledAt after loop completes to ensure all items at same timestamp are pulled
    if (lastUpdated != null) {
      final lastUpdatedMicros = lastUpdated.toUtc().microsecondsSinceEpoch;

      // Update pulledAt (and firstPulledAt on initial pull)
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: entity,
          pulledAt: Value(lastUpdatedMicros),
          firstPulledAt: initial
              ? Value(lastUpdatedMicros)
              : const Value.absent(),
        ),
        onConflict: DoUpdate(
          (old) => SyncStatesCompanion(
            entity: Value(entity),
            pulledAt: Value(lastUpdatedMicros),
            firstPulledAt: initial
                ? Value(lastUpdatedMicros)
                : const Value.absent(),
            // Preserve existing 'last' and 'noMore' values
          ),
        ),
      );
    } else if (initial) {
      // Set pulledAt and firstPulledAt for initial pull even if no rows (marks entity as initialized)
      final nowMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: entity,
          pulledAt: Value(nowMicros),
          firstPulledAt: Value(nowMicros),
        ),
        onConflict: DoUpdate(
          (old) => SyncStatesCompanion(
            entity: Value(entity),
            pulledAt: Value(nowMicros),
            firstPulledAt: Value(nowMicros),
            // Preserve existing 'last' and 'noMore' values
          ),
        ),
      );
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

  /// Helper method to generate archived entity name
  static String getArchivedEntityName(String entity) => '${entity}_archived';

  /// Pulls all archived items for entities that don't use pagination (all except Activity).
  /// This is a one-time full fetch of all archived items.
  /// Uses entity_archived suffix for tracking in SyncStates.
  /// Only sets pulledAt timestamp (no pagination tracking).
  Future<void> pullArchived<
    TABLE extends SyncableTable,
    DATA extends DataClass
  >(TableInfo<TABLE, DATA> table, BaseTable baseTable) async {
    final entity = getArchivedEntityName(baseTable.fullName);
    log.fine("pullArchived(${baseTable.table})");

    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();

    // Skip if already pulled
    if (syncState?.pulledAt != null) {
      log.fine("Archived items already pulled for $entity, skipping");
      return;
    }

    // Fetch all archived items (no range, no updatedSince, archived=true)
    var (baseRows, lastUpdated, _, _, _) = await baseTable.get(archived: true);

    if (baseRows.isNotEmpty) {
      log.info(
        "Pulled ${baseRows.length} archived rows from ${baseTable.table}",
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
      // Use insertOrReplace mode to ensure null values are explicitly set.
      // - insertAllOnConflictUpdate uses toColumns(true) which treats null as
      //   "don't update this column" - causing unarchived items to stay archived
      // - insertOrReplace deletes and re-inserts the row, ensuring all columns
      //   including nulls are set correctly
      batch.insertAll(table, storeRows, mode: InsertMode.insertOrReplace);
    });

    // Mark as pulled
    final nowMicros =
        lastUpdated?.toUtc().microsecondsSinceEpoch ??
        DateTime.now().toUtc().microsecondsSinceEpoch;
    await into(syncStates).insert(
      SyncStatesCompanion.insert(entity: entity, pulledAt: Value(nowMicros)),
      onConflict: DoUpdate(
        (old) => SyncStatesCompanion(
          entity: Value(entity),
          pulledAt: Value(nowMicros),
        ),
      ),
    );

    if (baseRows.isNotEmpty) {
      log.info("Synced archived ${baseTable.name}: ${baseRows.length} rows");
    }
  }

  // Queue for tracking in-progress pullTo calls to prevent concurrent pulls
  static final Map<String, Completer<DateTime?>?> _pullQueue = {};

  /// Gets sync states for an entity and all its ancestors.
  ///
  /// For priority-filtered entities like "activities:abc.def.ghi", this returns
  /// sync states for:
  /// - "activities:abc.def.ghi" (self)
  /// - "activities:abc.def" (parent)
  /// - "activities:abc" (grandparent)
  ///
  /// This allows descendant priorities to inherit sync progress from ancestors.
  Future<List<SyncState>> _getAncestorSyncStates(String entityName) async {
    // Parse entity name to extract path if present
    // Format: "activities:{path}" or "activities:{path}_archived"
    final parts = entityName.split(':');
    if (parts.length < 2) {
      // No path filtering, just return the single state if it exists
      final state = await (select(
        syncStates,
      )..where((row) => row.entity.equals(entityName))).getSingleOrNull();
      return state != null ? [state] : [];
    }

    final baseName = parts[0]; // "activities"
    final pathAndSuffix = parts[1]; // "abc.def.ghi" or "abc.def.ghi_archived"

    // Check for archived suffix
    final isArchived = pathAndSuffix.endsWith('_archived');
    final pathValue = isArchived
        ? pathAndSuffix.substring(0, pathAndSuffix.length - 9)
        : pathAndSuffix;

    // Build list of ancestor entity names by walking up the path
    final ancestorEntityNames = <String>[];
    final suffix = isArchived ? '_archived' : '';
    Path? currentPath = Path(pathValue);

    while (currentPath != null) {
      ancestorEntityNames.add('$baseName:${currentPath.value}$suffix');
      currentPath = currentPath.parent;
    }

    // Query all ancestor sync states in one query
    if (ancestorEntityNames.isEmpty) {
      return [];
    }

    final states = await (select(
      syncStates,
    )..where((row) => row.entity.isIn(ancestorEntityNames))).get();

    return states;
  }

  /// Pulls data up to a specific date boundary.
  ///
  /// For descending order (newest first, ascending=false):
  /// - Pulls from newest (syncState.last) back to [pullTo] (older date)
  ///
  /// For ascending order (oldest first, ascending=true):
  /// - Pulls from oldest (syncState.last) forward to [pullTo] (newer date)
  ///
  /// Returns the new last value (what it pulled to).
  ///
  /// Updates only the 'last' timestamp in sync state (pagination boundary).
  ///
  /// For archived pagination (Activity only), set [archived] to true.
  /// This uses a separate sync state with "_archived" suffix.
  Future<DateTime?> pullTo<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    DateTime? pullTo,
    bool ascending = true,
    bool archived = false,
  }) async {
    // Queue concurrent pulls for the same entity+direction combination
    // This prevents overlapping pulls even with different pullTo values
    final entityName = archived
        ? getArchivedEntityName(baseTable.fullName)
        : baseTable.fullName;
    final queueKey = '$entityName:$ascending';

    if (_pullQueue.containsKey(queueKey)) {
      log.fine("Pull already in progress for $queueKey, waiting...");
      return await _pullQueue[queueKey]!.future;
    }

    final completer = Completer<DateTime?>();
    _pullQueue[queueKey] = completer;

    try {
      // Get sync states for this entity and all ancestors
      final ancestorSyncStates = await _getAncestorSyncStates(entityName);
      final syncState = ancestorSyncStates
          .where((s) => s.entity == entityName)
          .firstOrNull;

      // Check if we've already reached the end (noMore flag)
      if (syncState?.noMore == true) {
        log.fine(
          "No more data for entity $entityName (noMore=true), skipping pull",
        );
        completer.complete(null);
        return null;
      }

      // Find the oldest sync boundary among ancestors (for descending)
      // or newest boundary (for ascending)
      // This allows us to inherit sync progress from parent priorities
      final ancestorStates = ancestorSyncStates.where(
        (s) => s.entity != entityName && s.last != null,
      );

      int? effectiveLast = syncState?.last;

      if (ancestorStates.isNotEmpty) {
        final ancestorLast = ancestorStates.fold<int?>(null, (oldest, current) {
          if (oldest == null) return current.last;
          // For descending (newest first): smaller microseconds = older date = further back
          // We want the furthest back (oldest) boundary
          // For ascending (oldest first): larger microseconds = newer date = further forward
          // We want the furthest forward (newest) boundary
          return ascending
              ? (current.last! > oldest ? current.last : oldest)
              : (current.last! < oldest ? current.last : oldest);
        });

        if (ancestorLast != null) {
          if (effectiveLast == null) {
            effectiveLast = ancestorLast;
            log.fine(
              "Inheriting sync boundary from ancestor: ${DateTime.fromMicrosecondsSinceEpoch(ancestorLast, isUtc: true)}",
            );
          } else {
            // Use the better boundary (further back for descending, further forward for ascending)
            final oldEffective = effectiveLast;
            effectiveLast = ascending
                ? (ancestorLast > effectiveLast ? ancestorLast : effectiveLast)
                : (ancestorLast < effectiveLast ? ancestorLast : effectiveLast);

            if (oldEffective != effectiveLast) {
              log.fine(
                "Using ancestor's better sync boundary: ${DateTime.fromMicrosecondsSinceEpoch(effectiveLast, isUtc: true)} (was: ${DateTime.fromMicrosecondsSinceEpoch(oldEffective, isUtc: true)})",
              );
            }
          }
        }
      }

      // Build requestRange based on pullTo and effectiveLast
      DateTimeRange? requestRange;
      var totalRows = 0;
      var more = false;
      DateTime? lastUpdated;

      if (pullTo != null && effectiveLast != null) {
        final lastSynced = DateTime.fromMicrosecondsSinceEpoch(
          effectiveLast,
          isUtc: true,
        );

        if (ascending) {
          // Ascending: pull forward from last to pullTo
          // Check if already synced (by self or ancestor)
          if (!pullTo.isAfter(lastSynced)) {
            log.fine(
              "pullTo=$pullTo is already synced (effective last: $lastSynced), skipping pull",
            );
            completer.complete(null);
            return null;
          }
          requestRange = DateTimeRange(lastSynced, null);
        } else {
          // Descending: pull backward from pullTo to last
          // Check if already synced (by self or ancestor)
          if (!pullTo.isBefore(lastSynced)) {
            log.fine(
              "pullTo=$pullTo is already synced (effective last: $lastSynced), skipping pull",
            );
            completer.complete(null);
            return null;
          }
          // Fetch next page of items < last (older than current boundary)
          // Don't limit by pullTo - just continue paginating backwards
          requestRange = DateTimeRange(null, lastSynced);
        }
      } else if (effectiveLast != null) {
        // Pagination without specific target
        final currentLast = DateTime.fromMicrosecondsSinceEpoch(
          effectiveLast,
          isUtc: true,
        );
        requestRange = ascending
            ? DateTimeRange(currentLast, null) // Continue forward
            : DateTimeRange(null, currentLast); // Continue backward
      }

      log.fine("Requesting range $requestRange");

      var (baseRows, batchLastUpdated, _, newRange, batchMore) = await baseTable
          .get(range: requestRange, updatedSince: null, archived: archived);
      more = batchMore;
      if (batchLastUpdated != null) {
        lastUpdated = batchLastUpdated;
      }

      // Filter out items already synced via pull() using firstPulledAt
      if (syncState?.firstPulledAt != null && baseRows.isNotEmpty) {
        final firstPulled = DateTime.fromMicrosecondsSinceEpoch(
          syncState!.firstPulledAt!,
          isUtc: true,
        );
        baseRows = baseRows.where((row) {
          final updatedAt = DateTime.parse(row['updated_at'] as String);
          return updatedAt.isBefore(firstPulled) ||
              updatedAt.isAtSameMomentAs(firstPulled);
        }).toList();
      }

      if (baseRows.isNotEmpty) {
        log.info("Pulled ${baseRows.length} rows from ${baseTable.table}");
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

      // Allow base table to merge with local pending state
      final processedRows = await baseTable.processPulledRows(this, storeRows);

      await batch((batch) {
        // Use insertOrReplace mode to ensure null values are explicitly set.
        // - insertAllOnConflictUpdate uses toColumns(true) which treats null as
        //   "don't update this column" - causing unarchived items to stay archived
        // - insertOrReplace deletes and re-inserts the row, ensuring all columns
        //   including nulls are set correctly
        batch.insertAll(table, processedRows, mode: InsertMode.insertOrReplace);
      });

      totalRows += baseRows.length;

      // Update sync state with pagination boundary and noMore flag
      if (baseRows.isNotEmpty && lastUpdated != null) {
        // Use the last row in the batch as the pagination boundary
        // For descending: baseRows.last = oldest item (boundary moving backwards)
        // For ascending: baseRows.last = newest item (boundary moving forwards)
        final boundaryRowCreatedAt = DateTime.parse(
          baseRows.last[baseTable.order] as String,
        );
        final createdAtMicros = boundaryRowCreatedAt
            .toUtc()
            .microsecondsSinceEpoch;

        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entityName,
            last: Value(createdAtMicros),
            noMore: Value(!more),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entityName),
              last: Value(createdAtMicros),
              noMore: Value(!more),
              // Preserve existing 'pulledAt' and 'firstPulledAt' values
            ),
          ),
        );
      } else if (!more) {
        // No rows fetched but server says no more - set noMore flag
        await into(syncStates).insert(
          SyncStatesCompanion.insert(
            entity: entityName,
            noMore: const Value(true),
          ),
          onConflict: DoUpdate(
            (old) => SyncStatesCompanion(
              entity: Value(entityName),
              noMore: const Value(true),
              // Preserve all other values
            ),
          ),
        );
      }

      if (totalRows > 0) {
        log.info("Synced ${baseTable.name}: $totalRows rows");
      }

      // Return the range that was pulled
      // For descending tables, syncState.last is the oldest boundary
      // Return (oldest, null) to represent the range from oldest onwards
      final finalSyncState = await (select(
        syncStates,
      )..where((row) => row.entity.equals(entityName))).getSingleOrNull();

      final result = finalSyncState?.last != null
          ? DateTime.fromMicrosecondsSinceEpoch(
              finalSyncState!.last!,
              isUtc: true,
            )
          : null;

      completer.complete(result);
      return result;
    } catch (e, stackTrace) {
      completer.completeError(e, stackTrace);
      rethrow;
    } finally {
      _pullQueue.remove(queueKey);
    }
  }

  Future<void> _syncAll() async {
    try {
      // Use orchestrator for dependency-aware sync
      // This pulls all entities (parents→children), then pushes all (children→parents)
      await SyncOrchestrator.instance.syncAll();
      _resetAuthFailures();
    } catch (e, stackTrace) {
      // Check if this is an auth error - if so, schedule retry
      if (_isAuthError(e)) {
        log.warning("Auth error during sync", e, stackTrace);
        _handleAuthError();
        rethrow; // Stop sync on auth errors
      } else if (_isRlsViolation(e)) {
        log.warning(
          "RLS policy violation during sync - this indicates an app bug",
          e,
          stackTrace,
        );

        // Report RLS violations to PostHog (indicates app bugs)
        Tracker.trackError(
          'database',
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: stackTrace.toString(),
          context: 'sync_rls_violation',
        );
      }
      // Network errors and other issues are logged but don't stop the app
      log.warning("Error during _syncAll", e, stackTrace);
    }
  }

  Future<void> _handleTableSync(String table) async {
    log.fine("Syncing $table");
    try {
      // Map table name to SyncEntity using orchestrator
      final entity = SyncOrchestrator.getEntityByTableName(table);

      if (entity == null) {
        log.warning("Unknown table update for $table");
        return;
      }

      // Use orchestrator for dependency-aware push
      if (!await SyncOrchestrator.instance.push(entity)) {
        log.warning("${entity.debugName} push failed during table sync");
      }

      // Pull dependencies first (e.g., pull actors before notes)
      for (final dep in entity.dependsOn) {
        await SyncOrchestrator.instance.pull(dep);
      }

      // Pull updates for this entity
      await SyncOrchestrator.instance.pull(entity);
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

    if (_isBufferingBroadcasts) {
      _bufferedTables.add(table);
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

      // Subscribe to WebSocket FIRST, buffering messages during sync
      _isBufferingBroadcasts = true;
      _bufferedTables.clear();
      await _subscribeToUpdates();

      await _syncAll();

      // Process any messages received during sync
      _isBufferingBroadcasts = false;
      for (final table in _bufferedTables) {
        _syncDebouncer(table);
      }
      _bufferedTables.clear();
    } finally {
      _isBufferingBroadcasts = false;
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

            // Report unexpected errors to PostHog (filter out network errors)
            if (!SyncOrchestrator.instance._isExpectedError(error)) {
              Tracker.trackError(
                'sync',
                errorType: error.runtimeType.toString(),
                errorMessage: error.toString(),
                stackTrace: stackTrace.toString(),
                context: 'sync_connectivity',
              );
            }

            return null;
          });
        }
      });
    } catch (e, t) {
      log.warning("Error setting up connectivity listener", e, t);

      // Report connectivity listener setup errors to PostHog
      Tracker.trackError(
        'sync',
        errorType: e.runtimeType.toString(),
        errorMessage: e.toString(),
        stackTrace: t.toString(),
        context: 'sync_connectivity_setup',
      );
    }
  }

  Store._(User user)
    : super(
        driftDatabase(
          name: _databaseName(user.id),
          web: DriftWebOptions(
            sqlite3Wasm: Uri.parse('sqlite3.wasm'),
            driftWorker: Uri.parse('drift_worker.js'),
          ),
        ),
      );

  static String _databaseName(String userId) {
    final profile = CliArgs.profile;
    if (profile != null) {
      return 'plot-$userId-$profile';
    }
    return 'plot-$userId';
  }

  @override
  int get schemaVersion => 243;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await ActivityFts.createTable(m.database);
        await NoteFts.createTable(m.database);
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // =============================================================
        // Version 243: Final full reset for all pre-production schemas.
        // ALL versions <= 242 get a complete drop-and-recreate.
        // Future migrations (244+) MUST be incremental — see below.
        // =============================================================
        if (from <= 242) {
          await _dropAllUserObjects(m.database);
          await m.createAll();
          await ActivityFts.createTable(m.database);
          await NoteFts.createTable(m.database);
          return;
        }

        // --- Incremental migrations (add new versions here) ---
        // if (from < 244) {
        //   await m.addColumn(activities, activities.newColumn);
        // }
        // if (from < 245) {
        //   await m.alterTable(TableMigration(priorities));
        // }

        // Always recreate views and FTS (they depend on table schemas)
        for (final entity in allSchemaEntities) {
          if (entity is ViewInfo) {
            await m.drop(entity);
          }
        }
        await m.createAll(); // CREATE VIEW/TABLE IF NOT EXISTS — only views get recreated since tables already exist
        await ActivityFts.createTable(m.database);
        await NoteFts.createTable(m.database);
      },
      beforeOpen: (details) async {
        // Validate critical tables have expected columns. On web, OPFS may
        // survive "Clear site data" leaving a stale schema that passes
        // migration (CREATE TABLE IF NOT EXISTS) but fails at query time.
        try {
          await customSelect(
            'SELECT id, archived_at, root, created_at FROM priorities LIMIT 0',
          ).get();
        } catch (e) {
          log.warning('Database schema validation failed, rebuilding: $e');
          await _dropAllUserObjects(this);
          await Migrator(this).createAll();
          await ActivityFts.createTable(this);
          await NoteFts.createTable(this);
        }
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

  /// Drops ALL user-created objects from the SQLite database in dependency order
  /// (triggers → views → tables). Queries sqlite_master dynamically so it
  /// handles any schema state, including stale schemas left after partial
  /// browser storage clears on web.
  ///
  /// Uses try-catch per statement because FTS5 virtual tables create shadow
  /// tables (e.g. activity_fts_content, activity_fts_data) that cannot be
  /// dropped directly — they are auto-removed when the parent virtual table
  /// is dropped. Without per-statement error handling, a shadow table failure
  /// would abort the entire method and leave stale tables in place.
  static Future<void> _dropAllUserObjects(DatabaseConnectionUser db) async {
    // 1. Drop triggers
    final triggers = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name NOT LIKE 'sqlite_%'",
    ).get();
    for (final row in triggers) {
      final name = row.read<String>('name');
      try {
        await db.customStatement('DROP TRIGGER IF EXISTS "$name"');
      } catch (e) {
        log.fine('Failed to drop trigger $name: $e');
      }
    }

    // 2. Drop views
    final views = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'view' AND name NOT LIKE 'sqlite_%'",
    ).get();
    for (final row in views) {
      final name = row.read<String>('name');
      try {
        await db.customStatement('DROP VIEW IF EXISTS "$name"');
      } catch (e) {
        log.fine('Failed to drop view $name: $e');
      }
    }

    // 3. Drop tables (except internal sqlite tables).
    //    FTS5 shadow tables will fail here but succeed implicitly when their
    //    parent virtual table is dropped. A second pass catches stragglers.
    final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    ).get();
    for (final row in tables) {
      final name = row.read<String>('name');
      try {
        await db.customStatement('DROP TABLE IF EXISTS "$name"');
      } catch (e) {
        log.fine('Failed to drop table $name (may be FTS shadow table): $e');
      }
    }

    // 4. Second pass: pick up anything left (e.g. shadow tables whose parent
    //    was dropped after them in the first pass, freeing them).
    final remaining = await db.customSelect(
      "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view', 'trigger') AND name NOT LIKE 'sqlite_%'",
    ).get();
    for (final row in remaining) {
      final name = row.read<String>('name');
      final type = row.read<String>('type');
      final keyword = type == 'trigger' ? 'TRIGGER' : (type == 'view' ? 'VIEW' : 'TABLE');
      try {
        await db.customStatement('DROP $keyword IF EXISTS "$name"');
      } catch (e) {
        log.warning('Failed to drop $type $name on second pass: $e');
      }
    }
  }
}
