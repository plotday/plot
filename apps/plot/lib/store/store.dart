import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'dart:convert';
// Prefixed: store.dart's own [Priority] class (in priority.dart) shadows
// the scheduler one without it.
import 'package:flutter/scheduler.dart' as flutter_scheduler;
import 'package:flutter/widgets.dart'
    show
        AppLifecycleState,
        Brightness,
        IconData,
        WidgetsBinding,
        WidgetsBindingObserver,
        visibleForTesting;
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

import 'package:plot/util/string.dart';
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
import 'attention.dart';
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
part 'priority_block.dart';
part 'twist_instance.dart';
part 'twist_connection.dart';
part 'user_action.dart';
part 'thread.dart';
part 'link.dart';
part 'note.dart';
part 'thread_exception.dart';
part 'thread_tags.dart';
part 'note_tags.dart';
part 'thread_fts.dart';
part 'note_fts.dart';
part 'session.dart';
part 'tag.dart';
part 'thread_sub_type.dart';
part 'user_settings.dart';
part 'channel.dart';
part 'group.dart';

part 'store.g.dart';

/// Fire-and-forget [task] via the Flutter scheduler at [Priority.idle], so
/// it yields to in-flight rendering. Lets save() side effects (remote push,
/// AI summarization) overlap navigation transitions like the new-thread
/// submit → ThreadPage flip without competing for CPU during the frames
/// that actually paint the destination page.
void _deferIdle<T>(
  FutureOr<T> Function() task, {
  required String debugLabel,
}) {
  unawaited(
    flutter_scheduler.SchedulerBinding.instance.scheduleTask(
      task,
      flutter_scheduler.Priority.idle,
      debugLabel: debugLabel,
    ),
  );
}

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

/// Result of attempting to revert a local row to its server-side version
/// after a "permanent" push error.
///
/// - [reverted]: server had a version of this row; local was overwritten and
///   `pending` should be cleared.
/// - [absentOnServer]: server returned no row for this id. The local row is
///   kept; `pending` should stay set so the next sync retries. Treating a
///   not-yet-synced create as "deleted on the server" loses user data.
/// - [fetchFailed]: the GET itself errored out (network, 5xx). Same handling
///   as [absentOnServer]: keep local row, keep pending.
enum _RevertOutcome { reverted, absentOnServer, fetchFailed }

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
    this.limit = 200,
    this.cursorColumn = 'id',
  }) : name = name ?? "${table}s";

  final String table;

  /// The sync API endpoint path (e.g., 'threads', 'notes')
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

  /// Extract a DateTime-parseable string from the raw boundary value of the
  /// order column. Override when the order column is not a plain timestamp
  /// (e.g. a tstzrange like agenda_at).
  String? parseBoundaryValue(String? value) => value;

  /// Build query params for the sync API call.
  /// Subclasses override to add entity-specific params (e.g., priority_path).
  ///
  /// Two cursor modes are supported:
  /// - **seq cursor (preferred)**: pass [lastHorizon] (xid8 as decimal
  ///   string). The server filters `seq >= last_horizon AND seq <
  ///   pg_snapshot_xmin(pg_current_snapshot())`. [pageSeq] / [pageId] are
  ///   the within-pull pagination tiebreakers echoed back from the
  ///   server's previous `next_page`.
  /// - **legacy timestamp cursor**: pass [updatedSince] (+ [lastId]).
  ///   Kept for backwards compatibility while clients on schema <320 drain.
  Map<String, String> buildParams({
    DateTime? updatedSince,
    String? lastId,
    String? lastHorizon,
    String? pageSeq,
    String? pageId,
    bool initial = false,
    bool archived = false,
  }) {
    final params = <String, String>{};
    if (lastHorizon != null) {
      params['seq_since'] = lastHorizon;
      if (pageSeq != null) params['page_seq'] = pageSeq;
      if (pageId != null) params['page_id'] = pageId;
    } else if (updatedSince != null) {
      params['updated_since'] = updatedSince.toIso8601String();
      if (lastId != null) params['cursor_id'] = lastId;
    }
    if (initial) params['initial'] = 'true';
    if (supportsArchiving &&
        (updatedSince == null && lastHorizon == null || initial || archived)) {
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
      String? nextHorizon,
      ({String seq, String id})? nextPage,
    )
  >
  get({
    DateTimeRange? range,
    DateTime? updatedSince,
    String? lastId,
    String? lastHorizon,
    String? pageSeq,
    String? pageId,
    bool initial = false,
    bool archived = false,
  }) async {
    final useSeqCursor = lastHorizon != null;
    final params = buildParams(
      updatedSince: updatedSince,
      lastId: lastId,
      lastHorizon: lastHorizon,
      pageSeq: pageSeq,
      pageId: pageId,
      initial: initial,
      archived: archived,
    );

    // For non-cursor pulls, add sort params so server sorts consistently.
    // (Seq-cursor pulls always sort by `seq, id` server-side.)
    if (updatedSince == null && !useSeqCursor) {
      if (initial || archived) {
        // Initial and archived pulls must sort by updated_at ASC to match
        // the cursor sort used on page 2+ (when updatedSince is set)
        params['sort_by'] = 'updated_at';
        params['sort_dir'] = 'asc';
      } else {
        params['sort_by'] = order;
        params['sort_dir'] = ascending ? 'asc' : 'desc';
      }
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

    // Execute query with auth error detection. Seq-cursor responses are
    // wrapped in `{rows, next_page, next_horizon}`; legacy responses are
    // a bare array. We branch on `useSeqCursor` (whether we sent
    // `seq_since`) to know which shape to expect.
    late final List<Map<String, dynamic>> rows;
    String? nextHorizon;
    ({String seq, String id})? nextPage;
    try {
      if (useSeqCursor) {
        final envelope = await api.get<Map<String, dynamic>>(
          '/sync/$syncEndpoint${queryString.isNotEmpty ? '?$queryString' : ''}',
        );
        rows = (envelope['rows'] as List<dynamic>).cast<Map<String, dynamic>>();
        nextHorizon = envelope['next_horizon']?.toString();
        final np = envelope['next_page'];
        if (np is Map) {
          nextPage = (
            seq: np['seq'].toString(),
            id: np['id'].toString(),
          );
        }
      } else {
        final result = await api.get<List<dynamic>>(
          '/sync/$syncEndpoint${queryString.isNotEmpty ? '?$queryString' : ''}',
        );
        rows = result.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      if (Store._isAuthError(e)) {
        await Store._handleAuthError();
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
    // For update pulls (updatedSince/lastHorizon != null), sort is by
    // updated_at/seq not the primary order column, so created_at range
    // would be meaningless.
    if (updatedSince != null || useSeqCursor || initial || archived) {
      // Skip range computation for update/initial/archived pulls where sort
      // is overridden (order column values aren't sorted)
    } else if (range != null) {
      returnRange = range;
    } else if (rows.isNotEmpty) {
      final firstStr =
          (rows.first[order] ?? rows.first['created_at']) as String?;
      final lastStr = (rows.last[order] ?? rows.last['created_at']) as String?;
      if (firstStr != null && lastStr != null) {
        final firstTime = DateTime.parse(firstStr);
        final lastTime = DateTime.parse(lastStr);
        // For descending order, first row is newest, last row is oldest
        // DateTimeRange expects start <= end, so we need to swap for descending
        final start = ascending ? firstTime : lastTime;
        final end = ascending ? lastTime : firstTime;
        returnRange = DateTimeRange(start, end);
      }
    }
    DateTime? lastUpdated;
    String? returnLastId;
    if (rows.isNotEmpty && !useSeqCursor) {
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
      returnLastId = rows.last[cursorColumn]?.toString();
    }
    // For legacy: more = rows.length >= limit. For seq cursor: server-driven
    // via next_page (more iff nextPage != null).
    final more = useSeqCursor
        ? (nextPage != null)
        : (limit != null && rows.length >= limit!);
    return (rows, lastUpdated, returnLastId, returnRange, more, nextHorizon, nextPage);
  }

  Future<void> put(Iterable<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;

    try {
      for (final row in rows) {
        await api.post<Map<String, dynamic>>('/sync/$syncEndpoint', body: row);
      }
    } catch (e) {
      if (Store._isAuthError(e)) {
        await Store._handleAuthError();
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
    PriorityBlocks,
    TwistInstances,
    TwistConnections,
    Threads,
    Links,
    Notes,
    ThreadFts,
    NoteFts,
    Schedules,
    ThreadTags,
    NoteTags,
    Sessions,
    UserSettings,
    Channels,
    Groups,
    ThreadAssociations,
  ],
  include: {'priority.drift'},
)
class Store extends _$Store {
  static Store get get => Injector.appInstance.get<Store>();

  /// Whether a Store instance is available and not closing.
  /// Use this to guard database access in stream callbacks that may fire
  /// during shutdown.
  static bool get isAvailable =>
      Injector.appInstance.exists<Store>() && !get._closing;

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

  /// Optional callback for reporting status during start (e.g. to show on loading page).
  static void Function(String status)? onStartStatus;

  /// Notifies listeners when a full resync completes, so UI can re-trigger
  /// demand-driven syncs (e.g. pullActivityFeed, pullAgenda).
  static final onFullResync = StreamController<void>.broadcast();

  // Lock to prevent concurrent Store.start() calls
  static final Lock _startLock = Lock();
  // Track the current user to avoid unnecessary Store recreation
  static String? _currentUserId;
  static String? get currentUserId => _currentUserId;

  static Future<void> stop() async {
    _authRetryTimer?.cancel();
    _authRetryTimer = null;
    _syncRetryCount = 0;
    if (Injector.appInstance.exists<Store>()) {
      // Get reference before removing from injector
      final store = get;
      // Prevent new sync operations and cancel pending timers BEFORE
      // removing from injector or closing the database. This avoids a race
      // where a debouncer timer fires and executes a query against a
      // closing/closed SQLite connection (use-after-free → SIGSEGV).
      store._closing = true;
      store._syncDebouncer.dispose();
      store._connectivitySubscription?.cancel();
      store._connectivitySubscription = null;
      store._unsubscribeFromUpdates();
      // Wait for any in-flight sync to finish BEFORE removing Store from
      // the Injector. Sync code calls Store.get throughout — pulling Store
      // from the Injector mid-sync makes those lookups throw "type Store
      // is not defined". _drainActiveOperations is bounded (~5s) so an
      // offline or stuck sync still won't block shutdown.
      await store._drainActiveOperations();
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

      // Close existing store if it exists – use the same cleanup sequence
      // as stop() to prevent races where code accesses a closing Store.
      if (Injector.appInstance.exists<Store>()) {
        final old = get;
        old._closing = true;
        old._syncDebouncer.dispose();
        old._connectivitySubscription?.cancel();
        old._connectivitySubscription = null;
        old._unsubscribeFromUpdates();
        // Drain in-flight sync before removing from Injector — see stop().
        await old._drainActiveOperations();
        Injector.appInstance.removeByKey<Store>();
        await old.close();
      }

      var inst = Store._(user);
      Injector.appInstance.registerSingleton<Store>(() => inst, override: true);

      bool hasDefault;
      try {
        hasDefault = await Priority.hasDefault();
      } catch (e, stackTrace) {
        log.warning(
          'Priority.hasDefault() failed, attempting schema rebuild',
          e,
          stackTrace,
        );
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
          await ThreadFts.createTable(inst);
          await NoteFts.createTable(inst);
          hasDefault = false; // Schema was rebuilt, no data
        } catch (rebuildError, rebuildTrace) {
          log.warning('In-place rebuild failed', rebuildError, rebuildTrace);
          Tracker.trackError(
            'database',
            errorType: rebuildError.runtimeType.toString(),
            errorMessage: rebuildError.toString(),
            context: 'store_start_rebuild_failed',
          );
          // If SQLite itself is unavailable (e.g. missing DLL on Windows),
          // continuing is futile — rethrow so UserBloc signs out.
          rethrow;
        }
      }

      if (hasDefault) {
        // User has existing local data, start sync in background (non-blocking)
        inst._setupConnectivityListener();
        inst._setupLifecycleListener();
      } else {
        // New user or no local data - critical sync blocks, rest is deferred
        log.info("New user sync: starting connectivity check and critical sync");
        onStartStatus?.call('Connecting...');
        try {
          await Future(() async {
            await inst._waitForNetworkConnectivity();
            log.info("New user sync: connectivity confirmed, starting critical sync");
            onStartStatus?.call('Syncing your data...');
            await inst._startSyncCritical();
            log.info("New user sync: critical sync complete");
          }).timeout(const Duration(seconds: 30));
        } on TimeoutException {
          log.warning("New user critical sync timed out after 30s");
          Tracker.trackError(
            'auth',
            errorType: 'TimeoutException',
            errorMessage: 'New user critical sync timed out after 30s',
            context: 'sign_in_sync_timeout',
          );
          rethrow;
        }

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

        // Complete remaining sync in background, then set up connectivity
        inst._startSyncDeferred().whenComplete(() {
          inst._setupConnectivityListener();
          inst._setupLifecycleListener();
        });
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
      // 400 (Bad Request), 403 (Forbidden), 404 (Not Found), 409 (Conflict),
      // 422 (Unprocessable) are permanent errors that won't succeed on retry.
      // Exclude 401 (auth), 408 (timeout), 429 (rate limit) which are transient.
      const permanentStatuses = {400, 403, 404, 409, 422};
      return permanentStatuses.contains(error.statusCode);
    }
    return false;
  }

  /// Attempts to revert a local row to its server-side version. Never deletes
  /// the local row — if the server doesn't have this id, returns
  /// [_RevertOutcome.absentOnServer] and leaves the local copy alone so the
  /// caller can retry the push instead of dropping unsynced user data.
  Future<_RevertOutcome>
  _revertToRemote<TABLE extends SyncableTable, DATA extends DataClass>(
    BaseTable baseTable,
    TableInfo<TABLE, DATA> table,
    Map<String, dynamic> localRow,
  ) async {
    final id = localRow['id'] as Object;

    final List<dynamic> rows;
    try {
      rows = await api.get<List<dynamic>>(
        '/sync/${baseTable.syncEndpoint}?id=${Uri.encodeQueryComponent(id.toString())}',
      );
    } catch (e, trace) {
      log.warning(
        "Could not fetch remote version of ${baseTable.table} (ID: $id) — leaving local row pending for retry",
        e,
        trace,
      );
      return _RevertOutcome.fetchFailed;
    }

    final response = rows.isEmpty ? null : (rows.first as Map<String, dynamic>);
    if (response == null) {
      // Server has no version of this row. The local copy is most likely a
      // create that hasn't been acknowledged yet (e.g. parent row not pushed
      // yet, or a transient server outage that surfaced as a "permanent"
      // 4xx). Keep the row and let the next push retry.
      log.warning(
        "No remote version of ${baseTable.table} (ID: $id) — leaving local row pending for retry",
      );
      return _RevertOutcome.absentOnServer;
    }

    try {
      final remoteData = baseTable.fromBase(response);
      await batch((batch) {
        batch.insertAllOnConflictUpdate(table, [remoteData]);
      });
      log.warning(
        "Reverted local ${baseTable.table} (ID: $id) to remote version",
      );
      return _RevertOutcome.reverted;
    } catch (e, trace) {
      log.severe(
        "Failed to apply remote version of ${baseTable.table} (ID: $id)",
        e,
        trace,
      );
      return _RevertOutcome.fetchFailed;
    }
  }

  static int _syncRetryCount = 0;
  static Timer? _authRetryTimer;

  /// Verify the session with Clerk and act accordingly. If the session is
  /// definitively invalid, [Base.handleTokenResult] triggers sign-out. If
  /// it's a network error, schedule a retry with increasing backoff.
  ///
  /// `_handleAuthError` only fires after the API has returned 401 for a
  /// request that used a token we just fetched, so the cached JWT is
  /// known-bad. Pass `forceRefresh: true` so the auth layer goes back to
  /// Clerk's server rather than handing back the same stale JWT — without
  /// this we silently loop here forever on a server-side session
  /// revocation, sync cursors freeze, and the user sees stale data with
  /// no path to recovery.
  static Future<void> _handleAuthError() async {
    final result = await Base.getSessionTokenWithReason(forceRefresh: true);

    // Let Base decide: sessionInvalid → sign-out, success → clear flag.
    Base.handleTokenResult(result);

    // If sessionInvalid, Base will sign out — no retry needed.
    if (result.failure == TokenFailureReason.sessionInvalid) return;

    _scheduleAuthRetry();
  }

  /// Schedule a future `_startSync` with exponential backoff (capped at 5
  /// minutes). Used when a sync attempt couldn't get an auth token but the
  /// session isn't definitively dead.
  static void _scheduleAuthRetry() {
    _syncRetryCount++;
    final delaySec = min(30 * _syncRetryCount, 300);
    log.warning(
      "Auth error during sync (attempt $_syncRetryCount), retrying in ${delaySec}s",
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
    if (_syncRetryCount > 0) {
      log.info("Sync recovered after $_syncRetryCount auth failures");
    }
    _syncRetryCount = 0;
    _authRetryTimer?.cancel();
    _authRetryTimer = null;
  }

  BroadcastClient? _broadcastClient;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  _StoreLifecycleObserver? _lifecycleObserver;
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;
  bool _isOnline = false;
  bool _isBufferingBroadcasts = false;
  bool _closing = false;
  final _bufferedTables = <String>{};

  // Adaptive batch debouncer for sync requests — collects entity names
  // and syncs them together to eliminate redundant dependency pulls.
  // Sized to align with server-side UserSync batching (MIN_WAIT_MS=300ms,
  // MAX_WAIT_MS=2000ms): one server batch maps to one client batch.
  late final BatchDebouncer<String> _syncDebouncer = BatchDebouncer(
    maxInitialMs: 300,
    maxSubsequentMs: 2000,
    waitMs: 500,
    onBatchAll: _handleBatchSync,
  );

  Future<DATA> add<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    Insertable<DATA> data,
  ) async {
    if (_closing) {
      throw StateError(
          'Database is closing, cannot write to ${table.actualTableName}');
    }
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
    if (_closing) {
      throw StateError(
          'Database is closing, cannot batch write to ${table.actualTableName}');
    }
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
    } on StateError catch (e) {
      if (_closing) {
        log.fine("Suppressed write during close: $e");
        return;
      }
      rethrow;
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
    if (_closing) return false;
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
      // First fetch rows with pending changes and mark them as sync-in-progress.
      // Exclude draft rows and rows belonging to draft threads — they shouldn't
      // be pushed until published.
      final draftFilter = _buildDraftFilter(table);
      final List<QueryRow> pendingRows = await customWriteReturning(
        'UPDATE ${table.actualTableName} SET pending = pending | 1 WHERE pending IS NOT NULL$draftFilter RETURNING *',
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
                  await Store._handleAuthError();
                  rethrow;
                } else if (Store._isPermanentError(e)) {
                  // Server rejected this push as "permanent". Try to revert
                  // local to remote — but only clear `pending` if the server
                  // actually had a version we could revert to. If it didn't
                  // (or the GET failed), keep the row and leave `pending` set
                  // so the next sync retries. This protects unsynced creates
                  // when a transient symptom (e.g. parent not pushed yet, or a
                  // brief 5xx that surfaces as a "permanent" 4xx like 403)
                  // would otherwise have stranded the row.
                  final errorMsg = e is ApiException
                      ? e.description
                      : 'Invalid local change';
                  log.warning(
                    "Permanent error during sync (${baseTable.table}): $errorMsg",
                    e,
                    stackTrace,
                  );

                  final outcome = await _revertToRemote(
                    baseTable,
                    table,
                    baseTable.toBase(data),
                  );

                  if (outcome == _RevertOutcome.reverted) {
                    await customUpdate(
                      'UPDATE ${table.actualTableName} SET pending = NULL WHERE id = ?',
                      variables: [Variable(row.data['id'])],
                      updates: {table},
                    );
                  }
                  // For absentOnServer / fetchFailed: leave `pending` set —
                  // the row stays in the queue and the next push retries.
                  // Don't set success = true (this wasn't a successful push).
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

  /// Returns a SQL WHERE clause fragment to exclude draft-related rows from push.
  ///
  /// - Tables with a `draft` column: exclude rows where draft = true
  /// - Tables with a `thread_id` column: exclude rows whose thread is draft
  /// - Tag tables (note_tags, thread_tags): exclude rows whose parent is draft
  static String _buildDraftFilter(TableInfo<Table, DataClass> table) {
    final columns = table.$columns;
    final name = table.actualTableName;

    // Tables with their own draft column (threads, notes)
    if (columns.any((c) => c.$name == 'draft')) {
      return ' AND draft = 0';
    }

    // Tables with thread_id FK (schedules, links, etc.)
    if (columns.any((c) => c.$name == 'thread_id')) {
      return ' AND (thread_id IS NULL OR thread_id NOT IN'
          ' (SELECT id FROM threads WHERE draft = 1))';
    }

    // Tag tables that share id with their parent
    if (name == 'note_tags') {
      return ' AND id NOT IN (SELECT id FROM notes WHERE draft = 1)';
    }
    if (name == 'thread_tags') {
      return ' AND id NOT IN (SELECT id FROM threads WHERE draft = 1)';
    }

    return '';
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
  /// - [PullType.more]: Pagination pull (typically for threads)
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

    // Initial pull: skip if a horizon (or legacy pulledAt) already exists.
    final initialized =
        syncState?.lastHorizon != null || syncState?.pulledAt != null;
    if (initial && initialized) {
      return null;
    }

    // Determine starting horizon. NULL → "0" (fetch from beginning). On the
    // first incremental pull post-schema-320 (where the migration nulled
    // pulledAt), this starts from 0 and re-fetches everything visible —
    // auto-recovery for users whose updated_at cursor was corrupted by the
    // long-transaction race.
    var lastHorizonStr = syncState?.lastHorizon != null
        ? syncState!.lastHorizon.toString()
        : "0";
    String? pageSeq;
    String? pageId;
    String? finalHorizon;
    var totalRows = 0;
    var more = false;

    do {
      var (
        baseRows,
        _,
        _,
        _,
        batchMore,
        nextHorizon,
        nextPage,
      ) = await baseTable.get(
        lastHorizon: lastHorizonStr,
        pageSeq: pageSeq,
        pageId: pageId,
        initial: initial,
      );
      more = batchMore;
      if (nextPage != null) {
        pageSeq = nextPage.seq;
        pageId = nextPage.id;
      }
      // The server returns next_horizon on every response; we only commit
      // it to syncStates after the pagination loop completes (when
      // nextPage == null), so a partial drain doesn't advance the cursor
      // past unfetched rows.
      if (nextHorizon != null) {
        finalHorizon = nextHorizon;
      }

      log.fine(
        "Pulling ${baseRows.length} rows from ${baseTable.table} (initial: $initial, more: $more)",
      );
      final storeRows = baseRows.expand<Insertable<DataClass>>((r) {
        try {
          return [baseTable.fromBase(r)];
        } catch (e, stackTrace) {
          log.warning(
            "Error parsing row ${jsonEncode(r, toEncodable: (o) => o.toString())} from ${baseTable.table}",
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
    } while (more);

    if (totalRows > 0) {
      log.fine("Synced ${baseTable.name}: $totalRows rows");
    }

    // Persist the new horizon. Also stamp `pulledAt` to now() so legacy
    // code paths that check `pulledAt != null` to detect "entity is
    // initialized" continue to work during the expand-contract rollout.
    final shouldStamp =
        finalHorizon != null ||
        (initial && baseTable.filterName == null);
    if (shouldStamp) {
      final horizonInt = finalHorizon != null
          ? int.tryParse(finalHorizon)
          : null;
      final nowMicros = DateTime.now().toUtc().microsecondsSinceEpoch;
      await into(syncStates).insert(
        SyncStatesCompanion.insert(
          entity: entity,
          lastHorizon: horizonInt != null
              ? Value(horizonInt)
              : const Value.absent(),
          pulledAt: Value(nowMicros),
          firstPulledAt: initial ? Value(nowMicros) : const Value.absent(),
        ),
        onConflict: DoUpdate(
          (old) => SyncStatesCompanion(
            entity: Value(entity),
            lastHorizon: horizonInt != null
                ? Value(horizonInt)
                : const Value.absent(),
            pulledAt: Value(nowMicros),
            firstPulledAt: initial ? Value(nowMicros) : const Value.absent(),
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

  /// Pulls all archived items for entities that don't use pagination (all except Thread).
  /// This is a one-time full fetch of all archived items.
  /// Uses entity_archived suffix for tracking in SyncStates.
  /// Only sets pulledAt timestamp (no pagination tracking).
  Future<void> pullArchived<
    TABLE extends SyncableTable,
    DATA extends DataClass
  >(TableInfo<TABLE, DATA> table, BaseTable baseTable) async {
    if (_closing) return;
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

    // Fetch all archived items with pagination
    DateTime? lastUpdated;
    String? lastId;
    var totalRows = 0;
    bool more;

    do {
      var (
        baseRows,
        batchLastUpdated,
        batchLastId,
        _,
        batchMore,
        _,
        _,
      ) = await baseTable.get(
        archived: true,
        updatedSince: lastUpdated,
        lastId: lastId,
      );
      more = batchMore && batchLastUpdated != null;
      if (batchLastUpdated != null) {
        lastUpdated = batchLastUpdated;
        lastId = batchLastId;
      }

      log.fine(
        "Pulling ${baseRows.length} archived rows from ${baseTable.table} (more: $more)",
      );

      final storeRows = baseRows.expand<Insertable<DataClass>>((r) {
        try {
          return [baseTable.fromBase(r)];
        } catch (e, stackTrace) {
          log.warning(
            "Error parsing row ${jsonEncode(r, toEncodable: (o) => o.toString())} from ${baseTable.table}",
            e,
            stackTrace,
          );
          return [];
        }
      });

      await batch((batch) {
        batch.insertAll(table, storeRows, mode: InsertMode.insertOrReplace);
      });
      totalRows += baseRows.length;
    } while (more);

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

    if (totalRows > 0) {
      log.info("Synced archived ${baseTable.name}: $totalRows rows");
    }
  }

  // Queue for tracking in-progress pullTo calls to prevent concurrent pulls
  static final Map<String, Completer<DateTime?>?> _pullQueue = {};

  /// Gets sync states for an entity and all its ancestors.
  ///
  /// For priority-filtered entities like "threads:abc.def.ghi", this returns
  /// sync states for:
  /// - "threads:abc.def.ghi" (self)
  /// - "threads:abc.def" (parent)
  /// - "threads:abc" (grandparent)
  ///
  /// This allows descendant priorities to inherit sync progress from ancestors.
  Future<List<SyncState>> _getAncestorSyncStates(String entityName) async {
    // Parse entity name to extract path if present
    // Format: "threads:{path}" or "threads:{path}_archived"
    final parts = entityName.split(':');
    if (parts.length < 2) {
      // No path filtering, just return the single state if it exists
      final state = await (select(
        syncStates,
      )..where((row) => row.entity.equals(entityName))).getSingleOrNull();
      return state != null ? [state] : [];
    }

    final baseName = parts[0]; // "threads"
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
  /// For archived pagination (Thread only), set [archived] to true.
  /// This uses a separate sync state with "_archived" suffix.
  Future<DateTime?> pullTo<TABLE extends SyncableTable, DATA extends DataClass>(
    TableInfo<TABLE, DATA> table,
    BaseTable baseTable, {
    DateTime? pullTo,
    DateTime? rangeStart,
    bool ascending = true,
    bool archived = false,
  }) async {
    if (_closing) return null;
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
      // Also check ancestors — if a parent priority has synced all data,
      // the child's data is a subset and is also fully synced.
      final anyNoMore =
          syncState?.noMore == true ||
          ancestorSyncStates.any(
            (s) => s.entity != entityName && s.noMore == true,
          );
      if (anyNoMore) {
        log.fine(
          "No more data for entity $entityName (noMore from self or ancestor), skipping pull",
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

      // For ascending pagination, clamp effectiveLast upward to rangeStart
      // so we never fetch items before the floor (e.g. agenda starts from now)
      if (ascending && rangeStart != null) {
        final rangeStartMicros = rangeStart.toUtc().microsecondsSinceEpoch;
        if (effectiveLast == null || effectiveLast < rangeStartMicros) {
          effectiveLast = rangeStartMicros;
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

      var (baseRows, batchLastUpdated, _, newRange, batchMore, _, _) =
          await baseTable.get(
        range: requestRange,
        updatedSince: null,
        archived: archived,
      );
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

      log.fine(
        "Pulled ${baseRows.length} rows from ${baseTable.table} (entity: $entityName, ascending: $ascending, archived: $archived, more: $more)",
      );

      // Capture boundary values before fromBase() which may mutate the maps
      final lastRowBoundary = baseRows.isNotEmpty
          ? baseRows.last[baseTable.order] as String?
          : null;
      final lastRowCreatedAt = baseRows.isNotEmpty
          ? baseRows.last['created_at'] as String?
          : null;

      final storeRows = baseRows.expand<Insertable<DataClass>>((r) {
        try {
          return [baseTable.fromBase(r)];
        } catch (e, stackTrace) {
          log.warning(
            "Error parsing row ${jsonEncode(r, toEncodable: (o) => o.toString())} from ${baseTable.table}",
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
        // (captured before fromBase() which may strip computed columns)
        // For descending: baseRows.last = oldest item (boundary moving backwards)
        // For ascending: baseRows.last = newest item (boundary moving forwards)
        var boundaryValue = baseTable.parseBoundaryValue(lastRowBoundary);
        if (boundaryValue == null) {
          // Fall back to created_at when sort column is null (e.g. infinity
          // timestamps that serialize to null, or missing computed columns)
          boundaryValue = lastRowCreatedAt;
          log.info(
            "Boundary value for ${baseTable.order} is null in last row of "
            "${baseTable.table}, falling back to created_at=$boundaryValue",
          );
          if (boundaryValue == null) {
            completer.complete(null);
            return null;
          }
        }
        final boundaryRowCreatedAt = DateTime.parse(boundaryValue);
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
    // Snapshot the count before sync. SyncOrchestrator swallows auth errors
    // (treats them as expected) so syncAll() can return normally even when every
    // operation got a 401. Only reset if no new auth failures occurred during
    // this sync — otherwise we'd falsely log "recovered" and reset the backoff.
    final countBefore = _syncRetryCount;
    try {
      // Use orchestrator for dependency-aware sync
      // This pulls all entities (parents→children), then pushes all (children→parents)
      await SyncOrchestrator.instance.syncAll();
      if (_syncRetryCount == countBefore) {
        _resetAuthFailures();
      }
    } catch (e, stackTrace) {
      // Check if this is an auth error - if so, schedule retry
      if (_isAuthError(e)) {
        log.warning("Auth error during sync", e, stackTrace);
        await _handleAuthError();
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

  Future<void> _handleBatchSync(Set<String> entityNames) async {
    if (_closing) return;
    log.fine("Batch syncing ${entityNames.join(', ')} via broadcast");
    try {
      final entities = entityNames
          .map(
            (name) => SyncOrchestrator.allEntities.firstWhereOrNull(
              (e) => e.debugName == name,
            ),
          )
          .nonNulls
          .toSet();

      if (entities.isEmpty) return;

      await SyncOrchestrator.instance.syncSubset(entities);
      onSyncBatchComplete?.call(entityNames);
    } catch (e, stackTrace) {
      log.warning("Error handling batch sync for $entityNames", e, stackTrace);
    }
  }

  /// Callback invoked after a WebSocket-triggered sync batch completes.
  /// Used by desktop notifications to detect when new data arrives.
  void Function(Set<String> syncedEntities)? onSyncBatchComplete;

  /// Callback invoked when a subscription change broadcast is received.
  void Function()? onSubscriptionChanged;

  Future<void> _subscribeToUpdates() async {
    _unsubscribeFromUpdates();

    _broadcastClient = BroadcastClient.instance;
    await _broadcastClient!.connect(
      _handleBroadcastMessage,
      clientId,
      onReconnected: _handleReconnected,
    );
  }

  void _handleReconnected() {
    if (_closing) return;
    log.info('WebSocket reconnected, triggering catch-up sync');
    _syncAll().catchError((Object error, StackTrace stackTrace) {
      log.warning('Reconnection-triggered sync failed', error, stackTrace);
      return null;
    });
    // Re-fetch subscription on reconnect since sync_user_on_connect clears
    // the pending user_sync row before the client can receive the broadcast.
    onSubscriptionChanged?.call();
  }

  Future<void> _handleBroadcastMessage(Map<String, dynamic> message) async {
    if (_closing) return;

    // Newer servers send `tables: [...]`; older servers send `table: '...'`.
    // Read whichever is present.
    final tablesRaw = message['tables'];
    final List<String> tables;
    if (tablesRaw is List) {
      tables = tablesRaw.whereType<String>().toList();
    } else {
      final single = message['table'] as String?;
      tables = single == null ? const [] : [single];
    }

    if (tables.isEmpty) {
      log.warning("Received broadcast message without table(s) field: $message");
      return;
    }

    for (final table in tables) {
      // Handle subscription changes (not a standard sync entity)
      if (table == 'subscription') {
        log.info("plot.store: Received subscription change broadcast");
        onSubscriptionChanged?.call();
        continue;
      }

      // Resolve to entity name before debouncing — prevents multiple table
      // names (e.g. thread, schedule, thread_read) from triggering redundant
      // syncs.
      final entity = SyncOrchestrator.getEntityByTableName(table);
      if (entity == null) {
        log.warning("Unknown table update for $table");
        continue;
      }

      log.info(
        "plot.store: Received broadcast table=$table entity=${entity.debugName}",
      );

      if (_isBufferingBroadcasts) {
        _bufferedTables.add(entity.debugName);
        continue;
      }

      _syncDebouncer(entity.debugName);
    }
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
      if (!completer.isCompleted &&
          results.any((result) => result != ConnectivityResult.none)) {
        log.info("Network connectivity restored");
        subscription.cancel();
        completer.complete();
      }
    });

    try {
      await completer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      log.warning("Connectivity check timed out after 15s — proceeding anyway");
      Tracker.trackError(
        'auth',
        errorType: 'TimeoutException',
        errorMessage: 'Network connectivity check timed out after 15s',
        context: 'sign_in_connectivity_timeout',
      );
      subscription.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  /// Critical sync for new users — blocks until minimum data is available.
  /// WebSocket is subscribed and broadcasts are buffered for the deferred phase.
  Future<void> _startSyncCritical() async {
    if (_closing) return;

    _isSyncing = true;
    try {
      _unsubscribeFromUpdates();
      await _waitForNetworkConnectivity();

      final tokenResult = await Base.getSessionTokenWithReason();
      if (tokenResult.failure != null) {
        Base.handleTokenResult(tokenResult);
        if (tokenResult.failure == TokenFailureReason.sessionInvalid) {
          log.warning('Session invalid before sync — skipping sync');
        } else {
          log.warning(
            'No session token before sync — skipping and scheduling retry',
          );
          _scheduleAuthRetry();
        }
        // Token-failure early-return: reset _isSyncing so the scheduled
        // retry (or any other caller) can actually run. The success path
        // intentionally leaves _isSyncing true for _startSyncDeferred.
        _isSyncing = false;
        return;
      }

      // Subscribe to WebSocket, buffering messages during sync
      _isBufferingBroadcasts = true;
      _bufferedTables.clear();
      await _subscribeToUpdates();

      await SyncOrchestrator.instance.syncInitialCritical();
    } catch (e) {
      // On failure, clean up buffering state so deferred phase doesn't hang
      _isBufferingBroadcasts = false;
      _isSyncing = false;
      rethrow;
    }
    // Note: _isSyncing and _isBufferingBroadcasts stay true for _startSyncDeferred
  }

  /// Deferred sync for new users — runs in background after app is interactive.
  Future<void> _startSyncDeferred() async {
    try {
      await SyncOrchestrator.instance.syncInitialDeferred();
      if (_closing) return;

      // Process any messages received during both sync phases
      _isBufferingBroadcasts = false;
      if (_bufferedTables.isNotEmpty) {
        log.fine(
          "Processing ${_bufferedTables.length} buffered broadcast tables",
        );
      }
      for (final table in _bufferedTables) {
        _syncDebouncer(table);
      }
      _bufferedTables.clear();
      _resetAuthFailures();
    } catch (e, stackTrace) {
      if (_isAuthError(e)) {
        log.warning("Auth error during deferred sync", e, stackTrace);
        await _handleAuthError();
      } else if (!SyncOrchestrator.instance._isExpectedError(e)) {
        Tracker.trackError(
          'sync',
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: stackTrace.toString(),
          context: 'sync_deferred',
        );
      }
      log.warning("Error during deferred sync", e, stackTrace);
    } finally {
      _isBufferingBroadcasts = false;
      _isSyncing = false;
    }
  }

  Future<void> _startSync() async {
    if (_closing) return;
    // Prevent concurrent sync attempts
    if (_isSyncing) {
      log.fine("Sync already in progress, skipping");
      return;
    }

    _isSyncing = true;
    try {
      _unsubscribeFromUpdates();
      await _waitForNetworkConnectivity();

      // Validate session before firing parallel sync requests. If the session
      // is definitively dead, bail out early instead of spamming 401s.
      final tokenResult = await Base.getSessionTokenWithReason();
      if (tokenResult.failure != null) {
        Base.handleTokenResult(tokenResult);
        if (tokenResult.failure == TokenFailureReason.sessionInvalid) {
          log.warning('Session invalid before sync — skipping sync');
        } else {
          log.warning(
            'No session token before sync — skipping and scheduling retry',
          );
          _scheduleAuthRetry();
        }
        return;
      }

      // Subscribe to WebSocket FIRST, buffering messages during sync
      _isBufferingBroadcasts = true;
      _bufferedTables.clear();
      await _subscribeToUpdates();

      await _syncAll();
      if (_closing) return;

      // Process any messages received during sync
      _isBufferingBroadcasts = false;
      if (_bufferedTables.isNotEmpty) {
        log.fine(
          "Processing ${_bufferedTables.length} buffered broadcast tables",
        );
      }
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

  void _setupLifecycleListener() {
    _lifecycleObserver = _StoreLifecycleObserver(this);
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
  }

  Store._(User user)
    : super(
        driftDatabase(
          name: _databaseName(user.id),
          // Skip setting sqlite3.tempDirectory — resolving the
          // sqlite3_temp_directory symbol can crash on Android with native
          // assets, and the system sqlite3 handles temp files on its own.
          native: DriftNativeOptions(tempDirectoryPath: () async => null),
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
  int get schemaVersion => 328;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await ThreadFts.createTable(m.database);
        await NoteFts.createTable(m.database);
        await _createPerfIndexes(m.database);
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
          await ThreadFts.createTable(m.database);
          await NoteFts.createTable(m.database);
          await _createPerfIndexes(m.database);
          return;
        }

        // --- Incremental migrations (add new versions here) ---
        // Wrapped in try-catch: if any step fails (e.g. due to partial state from
        // a previous failed migration — SQLite ALTER TABLE is auto-committed and
        // can't be rolled back), fall back to a full drop-and-recreate. Data will
        // be re-synced from the server.
        try {
          await _incrementalMigration(m, from);
        } catch (e) {
          log.warning(
            'Incremental migration from $from failed, doing full reset: $e',
          );
          await _dropAllUserObjects(m.database);
          await m.createAll();
          await ThreadFts.createTable(m.database);
          await NoteFts.createTable(m.database);
          await _createPerfIndexes(m.database);
          return;
        }

        // Always recreate views and FTS (they depend on table schemas)
        for (final entity in allSchemaEntities) {
          if (entity is ViewInfo) {
            await m.drop(entity);
          }
        }
        await m
            .createAll(); // CREATE VIEW/TABLE IF NOT EXISTS — only views get recreated since tables already exist
        await ThreadFts.createTable(m.database);
        await NoteFts.createTable(m.database);
        await _createPerfIndexes(m.database);
      },
      beforeOpen: (details) async {
        // Validate critical tables have expected columns. On web, OPFS may
        // survive "Clear site data" leaving a stale schema that passes
        // migration (CREATE TABLE IF NOT EXISTS) but fails at query time.
        // Probe one column from each recently-changed table so drift in
        // twist_instances (v302/v307), groups (v308), or threads.topic
        // (v308) triggers a rebuild alongside priorities drift.
        const probes = [
          'SELECT id, archived_at, root, created_at FROM priorities LIMIT 0',
          'SELECT id, updated_at, multiple_instances, is_builtin FROM twist_instances LIMIT 0',
          'SELECT id, updated_at FROM groups LIMIT 0',
          'SELECT id, topic, groups FROM threads LIMIT 0',
        ];
        for (final sql in probes) {
          try {
            await customSelect(sql).get();
          } catch (e) {
            log.warning('Database schema validation failed, rebuilding: $e');
            await _dropAllUserObjects(this);
            await Migrator(this).createAll();
            await ThreadFts.createTable(this);
            await NoteFts.createTable(this);
            break;
          }
        }
      },
    );
  }

  @override
  Future<void> close() async {
    _closing = true;
    _unsubscribeFromUpdates();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    if (_lifecycleObserver != null) {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
      _lifecycleObserver = null;
    }

    // Cancel all pending debounce timers
    _syncDebouncer.dispose();

    // Wait for in-flight sync operations to drain before closing the database
    // connection. This prevents a race where the background isolate's SQLite
    // update hook NativeCallable is invalidated while a write is still in
    // progress, causing a SIGSEGV (null function pointer call from sqlite3).
    await _drainActiveOperations();

    await super.close();
  }

  /// Waits for active push/pull/sync operations to complete, with a timeout.
  Future<void> _drainActiveOperations() async {
    const drainTimeout = Duration(seconds: 5);
    final deadline = DateTime.now().add(drainTimeout);

    // Poll until all tracked operations are idle or timeout is reached.
    while (DateTime.now().isBefore(deadline)) {
      final activePushes = List<Future<bool>>.of(
        _pushCompleters.values.map((c) => c.future),
      );
      final activePulls = List<Future<DateTime?>>.of(
        _pullQueue.values.whereType<Completer<DateTime?>>().map((c) => c.future),
      );

      if (activePushes.isEmpty && activePulls.isEmpty && !_isSyncing) {
        break;
      }

      // Wait for whichever finishes first: all active ops, or a short poll tick
      await Future.any([
        if (activePushes.isNotEmpty || activePulls.isNotEmpty)
          Future.wait([...activePushes, ...activePulls])
              .then((_) {})
              .catchError((_) {}),
        Future<void>.delayed(const Duration(milliseconds: 200)),
      ]);
    }

    // Final short delay so any last SQLite update-hook invocations complete
    // before the NativeCallable is torn down.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  static const _resyncSentinel = '1970-01-01T00:00:00.000Z';

  /// Performs a full re-sync from the server without losing local data.
  ///
  /// Marks all existing rows with a sentinel updatedAt (epoch), clears sync
  /// state, re-pulls everything from the server (which overwrites the sentinel
  /// on items that still exist), then deletes orphaned rows that still have
  /// the sentinel. Regular sync is suspended during the entire operation.
  Future<void> fullResync() async {
    // Wait briefly for any in-progress regular sync to finish (up to 5s)
    for (var i = 0; i < 50 && _isSyncing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_isSyncing) throw StateError('A sync is already in progress');
    _isSyncing = true;
    _isBufferingBroadcasts = true;
    _bufferedTables.clear();

    try {
      // 1. Push all pending local changes first
      final pushLevels = SyncOrchestrator.instance._computePushLevels();
      for (final level in pushLevels) {
        await Future.wait(level.map((e) => SyncOrchestrator.instance.push(e)));
      }

      // 2. Mark all syncable rows with sentinel updatedAt (skip pending rows)
      final syncableTables = <TableInfo<Table, DataClass>>[
        threads,
        notes,
        priorities,
        actors,
        schedules,
        links,
        sessions,
        twistInstances,
        channels,
        noteTags,
        threadTags,
        userSettings,
      ];
      for (final table in syncableTables) {
        await customStatement(
          "UPDATE ${table.actualTableName} SET updated_at = '$_resyncSentinel' WHERE pending IS NULL",
        );
      }

      // 3. Clear all sync states (makes initial pulls re-run)
      await delete(syncStates).go();

      // 4. Re-subscribe and run full sync cycle
      _unsubscribeFromUpdates();
      await _subscribeToUpdates();
      await _syncAll();

      // 4b. Pull first page of activity feed and agenda (global, no priority filter)
      // This ensures recent/relevant threads survive orphan deletion.
      await Thread.pullActivityFeed(null, null);
      await Thread.pullAgenda(null, null);

      // 5. Delete orphaned rows (still have sentinel, no pending changes)
      //    Delete children before parents to respect foreign key order
      final deleteOrder = <TableInfo<Table, DataClass>>[
        noteTags,
        threadTags,
        notes,
        schedules,
        links,
        sessions,
        channels,
        twistInstances,
        threads,
        priorities,
        actors,
        userSettings,
      ];
      for (final table in deleteOrder) {
        await customStatement(
          "DELETE FROM ${table.actualTableName} WHERE updated_at = '$_resyncSentinel' AND pending IS NULL",
        );
      }

      // 6. Clear view-level sync states (agenda/activity-feed) so demand-driven
      //    syncs run fresh. The global pulls above were only to protect rows from
      //    orphan cleanup — their noMore/boundary shouldn't block child syncs.
      await customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'agenda:%' OR entity LIKE 'activity-feed:%'",
      );

      // 7. Process buffered broadcast messages
      _isBufferingBroadcasts = false;
      for (final table in _bufferedTables) {
        _syncDebouncer(table);
      }
      _bufferedTables.clear();
      // 8. Notify listeners to re-trigger demand-driven syncs
      onFullResync.add(null);
    } finally {
      _isBufferingBroadcasts = false;
      _isSyncing = false;
    }
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
  Future<void> _incrementalMigration(Migrator m, int from) async {
    if (from < 244) {
      // Use raw SQL: table is still 'activities' until migration 246 renames it to 'threads',
      // and column is still 'links' until migration 246 renames it to 'actions'.
      await m.database.customStatement(
        'ALTER TABLE activities ADD COLUMN links TEXT',
      );
    }
    if (from < 245) {
      // These columns are added here and then removed in migration 247.
      // Use raw SQL: table is still 'activities' until migration 246 renames it to 'threads'.
      for (final col in [
        'user_start_on TEXT',
        'user_end_on TEXT',
        'user_order REAL',
        'user_state_updated INTEGER',
      ]) {
        await _safeCustomStatement(m, 'ALTER TABLE activities ADD COLUMN $col');
      }
    }
    if (from < 246) {
      // Rename tables: activities → threads, activity_exceptions → thread_exceptions, activity_tags → thread_tags
      await m.database.customStatement(
        'ALTER TABLE activities RENAME TO threads',
      );
      await m.database.customStatement(
        'ALTER TABLE activity_exceptions RENAME TO thread_exceptions',
      );
      await m.database.customStatement(
        'ALTER TABLE activity_tags RENAME TO thread_tags',
      );
      // Rename column: notes.activity_id → notes.thread_id
      await m.database.customStatement(
        'ALTER TABLE notes RENAME COLUMN activity_id TO thread_id',
      );
      // Rename column: thread_exceptions.activity_id → thread_exceptions.thread_id
      await m.database.customStatement(
        'ALTER TABLE thread_exceptions RENAME COLUMN activity_id TO thread_id',
      );
      // Rename column: threads.links → threads.actions
      await m.database.customStatement(
        'ALTER TABLE threads RENAME COLUMN links TO actions',
      );
      // Recreate FTS table: activity_fts → thread_fts
      await m.database.customStatement('DROP TABLE IF EXISTS activity_fts');
      // Update sync_states entity names to match new table names
      await m.database.customStatement(
        "UPDATE sync_states SET entity = 'threads' WHERE entity = 'activities'",
      );
      await m.database.customStatement(
        "UPDATE sync_states SET entity = 'thread_exceptions' WHERE entity = 'activity_exceptions'",
      );
      await m.database.customStatement(
        "UPDATE sync_states SET entity = 'thread_tags' WHERE entity = 'activity_tags'",
      );
    }
    if (from < 247) {
      // Create new schedules table
      await _safeCreateTable(m, schedules);
      // Migrate thread scheduling data to schedules
      await m.database.customStatement('''
        INSERT INTO schedules (id, updated_at, start_at, end_at,
            start_on, end_on, recurrence_rule, duration, recurrence_exdates, thread_id)
        SELECT lower(hex(randomblob(16))), updated_at, start_at, end_at,
            start_on, end_on, recurrence_rule, duration, recurrence_exdates, id
        FROM threads
        WHERE start_at IS NOT NULL OR start_on IS NOT NULL
      ''');
      // Migrate thread_exceptions to schedule occurrences
      await m.database.customStatement('''
        INSERT INTO schedules (id, updated_at, start_at, end_at,
            start_on, end_on, duration, occurrence, thread_id)
        SELECT lower(hex(randomblob(16))), updated_at, start_at, end_at,
            start_on, end_on, duration, occurrence, thread_id
        FROM thread_exceptions
      ''');
      // Migrate per-user state to schedules
      await m.database.customStatement('''
        INSERT INTO schedules (id, updated_at,
            start_on, end_on, "order", thread_id)
        SELECT lower(hex(randomblob(16))), updated_at,
            user_start_on, user_end_on, user_order, id
        FROM threads
        WHERE user_start_on IS NOT NULL
      ''');
      // Drop thread_exceptions table
      await m.database.customStatement(
        'DROP TABLE IF EXISTS thread_exceptions',
      );
      // Remove scheduling columns from threads (alterTable rebuilds without removed columns)
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(threads));
      // Update sync_states: remove thread_exceptions, reset threads sync
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity = 'thread_exceptions'",
      );
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity = 'threads'",
      );
    }
    if (from < 248) {
      await _safeAddColumn(m, schedules, schedules.contacts);
      await _safeAddColumn(m, schedules, schedules.currentUserStatus);
    }
    if (from < 249) {
      await _safeCreateTable(m, links);
      await _safeAddColumn(m, schedules, schedules.linkId);
      // Make threadId nullable (rebuild table with current schema)
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(schedules));
    }
    if (from < 250) {
      await _safeAddColumn(m, twistInstances, twistInstances.isSource);
    }
    if (from < 251) {
      // logo column was later removed in migration 255; use raw SQL
      await _safeCustomStatement(m, 'ALTER TABLE links ADD COLUMN logo TEXT');
    }
    if (from < 252) {
      await _safeAddColumn(m, links, links.sourceUrl);
    }
    if (from < 253) {
      await _safeAddColumn(m, links, links.createdBy);
    }
    if (from < 254) {
      await _safeAddColumn(m, twistInstances, twistInstances.linkTypes);
    }
    if (from < 255) {
      // Drop logo column from links (resolved from LinkTypeConfig now)
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(links));
    }
    if (from < 256) {
      // Drop removed thread fields: type, kind, order, doneAt, assigneeId,
      // authorId, sourceCreatedAt, actions
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(threads));
    }
    if (from < 257) {
      await _safeCustomStatement(
        m,
        'ALTER TABLE schedules ADD COLUMN done_at INTEGER',
      );
    }
    if (from < 258) {
      await _safeAddColumn(m, schedules, schedules.archivedAt);
    }
    if (from < 259) {
      // Account-based sources: add channelId to links, logoUrl to twistInstances,
      // make priorityId nullable, create channels table
      await _safeAddColumn(m, links, links.channelId);
      await _safeAddColumn(m, twistInstances, twistInstances.logoUrl);
      // Make priorityId nullable (rebuild table with current schema)
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(twistInstances));
      await _safeCreateTable(m, channels);
    }
    if (from < 260) {
      await _safeAddColumn(m, twistInstances, twistInstances.logoUrlDark);
    }
    if (from < 261) {
      await _safeAddColumn(m, links, links.priorityId);
      // create_threads column added here (later dropped in v294)
      await _safeCustomStatement(
        m,
        "ALTER TABLE channels ADD COLUMN create_threads INTEGER NOT NULL DEFAULT 1",
      );
      // thread_id nullable change requires table rebuild
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(links));
    }
    if (from < 262) {
      await _safeAddColumn(m, notes, notes.mergedFromThreadId);
      await _safeAddColumn(m, links, links.mergedFromThreadId);
    }
    if (from < 263) {
      await _safeAddColumn(m, links, links.logo);
    }
    if (from < 264) {
      await _safeAddColumn(m, userSettings, userSettings.aiEnabled);
      // Add bumpedAt to threads table
      await _safeAddColumn(m, threads, threads.bumpedAt);
      // Copy done_at from schedules to threads.bumped_at
      await _safeCustomStatement(m, '''
        UPDATE threads SET bumped_at = s.done_at
        FROM schedules s
        WHERE s.thread_id = threads.id AND s.done_at IS NOT NULL
      ''');
      // Archive schedules that had done_at set (they represent completed todos)
      await _safeCustomStatement(m, '''
        UPDATE schedules SET archived_at = done_at
        WHERE done_at IS NOT NULL AND archived_at IS NULL
      ''');
      // Drop doneAt column from schedules (Drift rebuilds table keeping only current columns)
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(schedules));
    }
    if (from < 265) {
      // organization_id column (later renamed to team_id in schema 293);
      // use raw SQL here because the Dart column has moved on.
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN organization_id INTEGER',
      );
      await _safeAddColumn(m, priorities, priorities.role);
      // priority_members table removed in per-user priorities migration;
      // keep the raw ALTER for users upgrading from older schema versions.
      await _safeCustomStatement(
        m,
        "ALTER TABLE priority_members ADD COLUMN role TEXT NOT NULL DEFAULT 'member'",
      );
    }
    if (from < 266) {
      await _safeAddColumn(
        m,
        twistInstances,
        twistInstances.defaultMentionCreated,
      );
      await _safeAddColumn(
        m,
        twistInstances,
        twistInstances.defaultMentionMentioned,
      );
    }
    if (from < 267) {
      await _safeAddColumn(m, twistInstances, twistInstances.userConnected);
    }
    if (from < 268) {
      // Original columns added as response_window/turnaround
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN response_window TEXT',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN turnaround TEXT',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN response_window_set INTEGER NOT NULL DEFAULT 0',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN turnaround_set INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (from < 269) {
      // Rename columns: response_window -> attention_window, turnaround -> see_within
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(
        priorities,
        columnTransformer: {
          priorities.attentionWindow: const CustomExpression('response_window'),
          priorities.attentionWindowSet: const CustomExpression('response_window_set'),
        },
      ));
    }
    if (from < 270) {
      await _safeAddColumn(m, schedules, schedules.reason);
    }
    if (from < 272) {
      await _safeAddColumn(m, threads, threads.importance);
    }
    if (from < 273) {
      await _safeAddColumn(m, threads, threads.urgency);
    }
    if (from < 274) {
      await _safeAddColumn(m, priorities, priorities.seeWithinRequests);
      await _safeAddColumn(m, priorities, priorities.seeWithinUpdates);
      await _safeAddColumn(m, priorities, priorities.seeWithinRequestsSet);
      await _safeAddColumn(m, priorities, priorities.seeWithinUpdatesSet);
    }
    if (from < 275) {
      // Drop see_within and see_within_set columns (replaced by see_within_requests/see_within_updates)
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(priorities));
    }
    if (from < 276) {
      // Convert create_threads int → text (later dropped in v294).
      await _safeCustomStatement(
        m,
        "ALTER TABLE channels RENAME COLUMN create_threads TO create_threads_old",
      );
      await _safeCustomStatement(
        m,
        "ALTER TABLE channels ADD COLUMN create_threads TEXT NOT NULL DEFAULT 'all'",
      );
      await _safeCustomStatement(
        m,
        "UPDATE channels SET create_threads = CASE WHEN create_threads_old = 1 THEN 'all' ELSE 'manual' END",
      );
      await _safeCustomStatement(
        m,
        "ALTER TABLE channels DROP COLUMN create_threads_old",
      );
    }
    if (from < 277) {
      await _safeAddColumn(m, schedules, schedules.outstandingTasks);
    }
    if (from < 278) {
      // (v278 originally deleted the row, but that doesn't work — see v279)
    }
    if (from < 279) {
      // Reset schedule sync cursor so the server-backfilled outstanding_tasks
      // values are re-pulled on next sync. Set to 0 (not delete) because
      // pull() without initial:true treats a missing cursor as "new entity"
      // and just sets it to now() without fetching.
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'schedules'",
      );
    }
    if (from < 280) {
      await _safeAddColumn(m, threads, threads.icon);
    }
    if (from < 281) {
      // Clean up spurious schedule rows created when toggling tags on
      // recurring event occurrences. These rows have occurrence set (from
      // the generated occurrence) but no link_id and no user_id, which
      // should never exist for shared thread-level schedules.
      await m.database.customStatement('''
        DELETE FROM schedules
        WHERE occurrence IS NOT NULL
          AND link_id IS NULL
          AND user_id IS NULL
      ''');
    }
    if (from < 283) {
      await _safeAddColumn(m, threads, threads.icon);
    }
    if (from < 284) {
      // Ensure icon column exists — earlier migrations may have targeted
      // the wrong table name. Try both possible names.
      await _safeCustomStatement(
        m,
        'ALTER TABLE activities ADD COLUMN icon TEXT',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE threads ADD COLUMN icon TEXT',
      );
    }
    if (from < 285) {
      // priority_actors table and actors.minDepth were added in 285
      // but removed in 306 — skip for fresh migrations past 306.
      if (from < 306) {
        // The columns were needed between 285-305; the table drop
        // happens in the 306 block below.
      }
    }
    if (from < 286) {
      // Reset twist_instances sync cursor so rows re-pull with the
      // int→BigInt fix in TwistInstancesBase.fromBase (twist_id was
      // silently failing to deserialize from server JSON).
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'twist_instances'",
      );
      // Also reset channels which has the same int→BigInt issue
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'channels'",
      );
    }
    if (from < 287) {
      // inherit_members column removed in schema 299; keep raw ADD for
      // users upgrading through older versions.
      await _safeCustomStatement(
        m,
        "ALTER TABLE priorities ADD COLUMN inherit_members INTEGER NOT NULL DEFAULT 1",
      );
    }
    if (from < 288) {
      await _safeAddColumn(m, channels, channels.linkTypes);
    }
    if (from < 289) {
      await _safeCreateTable(m, threadAssociations);
    }
    if (from < 290) {
      await m.addColumn(threads, threads.readAt);
      // Drop unreadUpdated by rebuilding the table (Drift keeps only current columns)
      await m.alterTable(TableMigration(threads));
    }
    if (from < 291) {
      await m.addColumn(twistInstances, twistInstances.shared);
      await m.addColumn(twistInstances, twistInstances.keyOption);
    }
    if (from < 292) {
      // Thread: previously added access and access_contacts columns (now
      // removed in the per-user-priorities migration). Add them temporarily
      // via raw SQL so the data migration runs, then rebuild drops them.
      try {
        await m.database.customStatement(
          "ALTER TABLE threads ADD COLUMN access TEXT NOT NULL DEFAULT 'public'",
        );
      } catch (_) {}
      try {
        await m.database.customStatement(
          "ALTER TABLE threads ADD COLUMN access_contacts TEXT",
        );
      } catch (_) {}
      await m.database.customStatement(
        "UPDATE threads SET access = CASE WHEN private = 1 THEN 'private' ELSE 'members' END WHERE access = 'public'",
      );
      // Drop old private, mentions, access, and access_contacts columns by
      // rebuilding the table to match the current Drift schema
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(threads));

      // Note: add access_contacts column, migrate from private
      await _safeAddColumn(m, notes, notes.accessContacts);
      await m.database.customStatement(
        "UPDATE notes SET access_contacts = CASE WHEN private = 1 THEN '[]' ELSE NULL END",
      );
      // Drop old private column by rebuilding the table
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(notes));

      // Reset sync cursors so threads and notes re-pull with new fields
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity LIKE 'threads%' OR entity LIKE 'notes%'",
      );
    }
    if (from < 293) {
      // Rename priorities.organization_id → priorities.team_id to match the
      // server schema. Use a column transformer so existing values survive.
      // ignore: experimental_member_use
      await m.alterTable(
        TableMigration(
          priorities,
          columnTransformer: {
            priorities.teamId: const CustomExpression<int>('organization_id'),
          },
        ),
      );
    }
    if (from < 294) {
      // Drop channels.create_threads (connector defaults are now hardcoded).
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(channels));
    }
    if (from < 295) {
      // Drop channels.priority_id — channels no longer route to priorities;
      // per-user matching handles thread routing.
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(channels));
    }
    if (from < 296) {
      // Twist instances become workspace-level: drop priority_id, add team_id
      // + draft to match the server schema.
      await _safeAddColumn(m, twistInstances, twistInstances.teamId);
      await _safeAddColumn(m, twistInstances, twistInstances.draft);
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(twistInstances));
    }
    if (from < 297) {
      // Per-user priorities, stage 8: mirror the server `thread.contacts`
      // field locally. The single-user client keeps priority_id directly
      // on the thread (no join table) — it tracks only the current user's
      // filing, which the server's `user.thread` view already denormalizes
      // from `thread_priority.priority_id`.
      await _safeAddColumn(m, threads, threads.contacts);
    }
    if (from < 298) {
      // Drop vestigial access/access_contacts columns from threads
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(threads));
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity LIKE 'threads%'",
      );
    }
    if (from < 299) {
      // Per-user priorities: drop priority_members table and inherit_members
      // column — priorities are per-user now, no sharing or member concepts.
      await m.database.customStatement('DROP TABLE IF EXISTS priority_members');
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'priority_member%' OR entity LIKE 'priority-member%'",
      );
      // ignore: experimental_member_use
      await m.alterTable(TableMigration(priorities));
    }
    if (from < 300) {
      // Historical: created the original `topics` table and thread.topics
      // column. Both are renamed to `groups`/`groups` in the v308 migration
      // below; raw SQL here keeps this step compiling against current Dart
      // classes (which no longer expose Topics / threads.topics).
      await _safeCustomStatement(
        m,
        '''
        CREATE TABLE IF NOT EXISTS topics (
          id BLOB NOT NULL PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          archived_at INTEGER,
          name TEXT NOT NULL,
          type TEXT NOT NULL,
          join_policy TEXT NOT NULL,
          team_id INTEGER,
          auto_maintained INTEGER NOT NULL DEFAULT 0,
          is_admin INTEGER NOT NULL DEFAULT 0,
          is_member INTEGER NOT NULL DEFAULT 0,
          member_contact_ids TEXT
        )
        ''',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE threads ADD COLUMN topics TEXT',
      );
    }
    if (from < 301) {
      await _safeAddColumn(m, threads, threads.inviteEmails);
    }
    if (from < 302) {
      await _safeAddColumn(m, twistInstances, twistInstances.isBuiltin);
    }
    if (from < 303) {
      await _safeCustomStatement(
        m,
        'ALTER TABLE threads ADD COLUMN has_embedding INTEGER NOT NULL DEFAULT 0',
      );
      // priority_rules table was created here previously. Removed — the
      // table is dropped unconditionally in the from<309 migration below,
      // and new installs don't need it (routing is now server-side).
    }
    if (from < 304) {
      // Re-sync links to pick up channel_id now included in user.link view.
      // Delete link rows so they get re-fetched with channel_id populated.
      await m.database.customStatement("DELETE FROM links");
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'links%'",
      );
    }
    if (from < 305) {
      // Reset channel sync so initial pull fetches all rows.
      // Channel.pull() previously called pull() without initial:true,
      // which set pulledAt without fetching, leaving channels empty.
      await m.database.customStatement("DELETE FROM channels");
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity = 'channels'",
      );
    }
    if (from < 306) {
      // Remove priority_actors table (actor visibility is now user-level)
      await m.database.customStatement("DROP TABLE IF EXISTS priority_actors");
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity = 'priority_actors'",
      );
      // Remove minDepth column from actors (was priority-scoped depth)
      await m.alterTable(TableMigration(actors));
    }
    if (from < 307) {
      await m.addColumn(twistInstances, twistInstances.multipleInstances);
    }
    if (from < 308) {
      // Split `topic` into `group` (contact grouping) + `thread.topic` (routing key).
      // Drift builds tables by class name (Topics → "topics"; Groups → "groups"),
      // so this migration reflects the class rename with SQL table renames.
      await m.database.customStatement('ALTER TABLE topics RENAME TO groups');
      // Rename sync state entry so the sync machinery keeps its cursor.
      await m.database.customStatement(
        "UPDATE sync_states SET entity = 'groups' WHERE entity = 'topics'",
      );
      // thread.topics → thread.groups; add thread.topic.
      await m.database.customStatement(
        'ALTER TABLE threads RENAME COLUMN topics TO groups',
      );
      await _safeAddColumn(m, threads, threads.topic);
      // priority_rules clean-up (drop channel_id + criteria, add topic)
      // from this migration moved to from<309 which drops the table
      // outright.
    }
    if (from < 309) {
      // Priority rules replaced by server-side user_moved flag on thread_priority.
      // Drop the ephemeral local table; routing is now learned from moves, not rules.
      await m.database.customStatement('DROP TABLE IF EXISTS priority_rules');
    }
    if (from < 310) {
      // Sparse per-priority config (topic/group/view behaviours), populated
      // by the server and read-only on the client.
      await _safeAddColumn(m, priorities, priorities.config);
    }
    if (from < 311) {
      await _safeAddColumn(m, actors, actors.inviteable);
    }
    if (from < 312) {
      // Clear per-thread notes/note_tags sync sentinels that were stamped
      // by the 0-row initial pull shortcut in Store.pull() (see 2026-04-18
      // Everyone-eviction incident). When a thread's user.note view was
      // temporarily empty due to a server-side visibility gap, the stamp
      // locked the client into "this thread is initialized" forever; the
      // notes never re-pulled even after the server restored visibility.
      // Clearing the rows lets _ensureNotesLoadedForActivity re-fire an
      // initial pull on the next thread open, and the updated Store.pull
      // logic no longer stamps filtered entities on empty responses.
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'notes:%' OR entity LIKE 'note_tags:%'",
      );
    }
    if (from < 313) {
      // Per-connection account disambiguator used as Connections subtitle and
      // composed into the actor display name (notes/mentions). Server populates
      // it from provider metadata (e.g. Google email, Slack workspace name);
      // user-editable in EditSource.
      await _safeAddColumn(m, twistInstances, twistInstances.accountLabel);
    }
    if (from < 314) {
      // Priority-level defaults that seed every new thread filed under the
      // priority with contacts/groups/invite emails. Nullable so a fresh sync
      // repopulates from the server.
      await _safeAddColumn(m, priorities, priorities.defaultContacts);
      await _safeAddColumn(m, priorities, priorities.defaultGroups);
      await _safeAddColumn(m, priorities, priorities.defaultInviteEmails);
      // Earlier builds of this change shipped a fromBase that couldn't parse
      // pg text-array strings and dropped default_groups on the floor. Clear
      // the priorities sync cursor so the next sync re-pulls every priority
      // with the fixed parser and the server-populated defaults land locally.
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'priorit%'",
      );
    }
    if (from < 315) {
      // Distinguishes canonical actors (primary linked contacts, external
      // contacts, twist instances) from non-primary linked-contact aliases
      // that are kept only for historical author resolution. Pickers filter
      // on primary=true so each person appears once.
      await _safeAddColumn(m, actors, actors.primary);
      // Clear the actors sync cursor so the next sync re-pulls every row
      // and stamps the correct primary flag (existing rows default to true).
      // Entity name is 'user_actors' (BaseTable.name = '${table}s', table = 'user_actor').
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'user_actors%'",
      );
    }
    if (from < 316) {
      // v315 used the wrong sync_states LIKE pattern ('actors%' instead of
      // 'user_actors%'), so the cursor never got cleared and existing local
      // actor rows kept the default primary=true. Re-clear with the correct
      // pattern so the next sync re-pulls every row with the server flag.
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'user_actors%'",
      );
    }
    if (from < 317) {
      // New per-(twist_instance, provider, actor) status mirror for
      // user.twist_connection. Surfaces re-auth and initial-sync state to
      // the app without overloading user.twist.
      await m.createTable(twistConnections);
    }
    if (from < 318) {
      // PK was (twist_instance_id, provider, actor_id) but the server's
      // per-user effective PK is (twist_instance_id, provider). When a
      // re-auth changed actor_id (e.g. user signed in with a different
      // linked email), pull's insertOrReplace inserted a new row alongside
      // the stale one, leaving needs_reauth=true behind and making the
      // re-auth button stick. Dedupe to the freshest row, then rebuild
      // the table with the corrected PK.
      await m.database.customStatement('''
        DELETE FROM twist_connections
        WHERE rowid NOT IN (
          SELECT rowid FROM (
            SELECT rowid,
                   ROW_NUMBER() OVER (
                     PARTITION BY twist_instance_id, provider
                     ORDER BY COALESCE(connected_at, '') DESC, rowid DESC
                   ) AS rn
            FROM twist_connections
          ) WHERE rn = 1
        )
      ''');
      await m.alterTable(TableMigration(twistConnections));
    }
    if (from < 319) {
      // Carries the contact's underlying user_id so two contact rows for the
      // same person (e.g. a primary email + a linked alias) collapse to one
      // entry in AvatarGroup and the share modal. Clear the actors sync
      // cursor so the next pull populates the column for every existing row.
      await _safeAddColumn(m, actors, actors.linkedUserId);
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'user_actors%'",
      );
    }
    if (from < 320) {
      // Sync cursor switches from updated_at (timestamp) to seq (xid8). Adds
      // a new column to track the seq watermark, then nulls pulled_at across
      // the board to force a fresh pull from `seq=0` on every entity. This
      // auto-recovers any users whose updated_at-based cursor was advanced
      // past a long-running transaction's rows (the bug we're fixing —
      // rows stamped with transaction-start time but committed after a
      // shorter overlapping txn became invisible to the cursor).
      await _safeAddColumn(m, syncStates, syncStates.lastHorizon);
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = NULL",
      );
    }
    if (from < 321) {
      // priority_block holds the per-priority order timeline used by the
      // agenda renderer. Empty initially; rows are written when the user
      // reorders a block.
      await m.createTable(priorityBlocks);
    }
    if (from < 322) {
      // groups.canPost mirrors user.group.can_post — whether the user is
      // allowed to send threads to the group (admins always; non-admins
      // only when they're members and the group is not 'announce'-typed).
      await _safeAddColumn(m, groups, groups.canPost);
      // The new column defaults to false on existing rows. Reset the
      // groups entity sync state so the next pull is a full refresh and
      // populates canPost from the server.
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = NULL, last_horizon = NULL, "
        "first_pulled_at = NULL, last = NULL, no_more = 0 "
        "WHERE entity = 'user_groups'",
      );
    }
    if (from < 323) {
      // Backfill the foreign-key indexes that earlier schema versions
      // never created. Drift only auto-indexes primary keys, so joins
      // through schedules/links/threads were doing per-row scans and the
      // search query (with its OR'd correlated EXISTS) was taking
      // multiple seconds on large databases.
      await _createPerfIndexes(m.database);
    }
    if (from < 324) {
      // Adds thread.mergedIntoThreadId so SplitThread can discover all sources
      // merged into a target by reverse-lookup. Existing archived merge sources
      // (pre-324) have NULL here and remain discoverable via the
      // notes.mergedFromThreadId / links.mergedFromThreadId fallback path.
      await _safeAddColumn(m, threads, threads.mergedIntoThreadId);
    }
    if (from < 325) {
      // Backfill idx_notes_thread_id. ThreadPage's Note.watch runs on every
      // navigation and was full-scanning the notes table.
      await _createPerfIndexes(m.database);
    }
    if (from < 326) {
      // Backfill idx_priorities_path. Priority._get's self-join uses
      // `p.path LIKE base.path || '%'` and the priority_ancestry view
      // joins on path — both full-scanned the priorities table on every
      // priority switch (~200ms standalone, much worse under contention).
      await _createPerfIndexes(m.database);
    }
    if (from < 327) {
      await _safeAddColumn(m, userSettings, userSettings.onboardingCompleted);
    }
    if (from < 328) {
      // Time-tracking feature: per-priority pending duration on priority_blocks,
      // event/manual source provenance + idempotency key on sessions,
      // global pause-tracking flag on user_settings.
      await _safeAddColumn(m, priorityBlocks, priorityBlocks.duration);
      await _safeAddColumn(m, sessions, sessions.source);
      await _safeAddColumn(m, sessions, sessions.scheduleId);
      await _safeAddColumn(m, sessions, sessions.occurrenceAt);
      await _safeAddColumn(m, userSettings, userSettings.trackingPausedAt);
    }
  }

  /// Foreign-key indexes used by the activity-feed and search queries.
  /// `IF NOT EXISTS` keeps this idempotent across migration paths.
  static Future<void> _createPerfIndexes(DatabaseConnectionUser db) async {
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_schedules_thread_id '
      'ON schedules(thread_id) WHERE thread_id IS NOT NULL',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_schedules_link_id '
      'ON schedules(link_id) WHERE link_id IS NOT NULL',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_schedules_user_id '
      'ON schedules(user_id) WHERE user_id IS NOT NULL',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_links_thread_id '
      'ON links(thread_id) WHERE thread_id IS NOT NULL',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_threads_priority_id '
      'ON threads(priority_id)',
    );
    // notes.thread_id is the hot path for ThreadPage: every open runs
    // `WHERE thread_id = ? ORDER BY source_created_at DESC` (Note.watch).
    // Without this index it was a full notes scan on every navigation.
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notes_thread_id ON notes(thread_id)',
    );
    // priorities.path is the workhorse for Priority._get's self-join
    // (`p.path LIKE base.path || '%'`) and for the recursive
    // priority_ancestry view. Without this index, every priority lookup
    // (didUpdateWidget on switch, sidebar load, _loadPriority's
    // Priority.watchOne) full-scans the priorities table — measured
    // ~200ms per call on a populated workspace. SQLite can use a btree
    // index for `LIKE 'prefix%'` patterns when the column has the
    // default BINARY collation, which it does here.
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_priorities_path ON priorities(path)',
    );
  }

  /// Runs a SQL statement, ignoring "duplicate column" and "already exists" errors.
  static Future<void> _safeCustomStatement(Migrator m, String sql) async {
    try {
      await m.database.customStatement(sql);
    } catch (e) {
      final msg = e.toString();
      if (!msg.contains('duplicate column') &&
          !msg.contains('already exists')) {
        rethrow;
      }
    }
  }

  /// Adds a column, ignoring "duplicate column" errors from previous partial migrations.
  /// SQLite ALTER TABLE is auto-committed and can't be rolled back on failure.
  static Future<void> _safeAddColumn(
    Migrator m,
    TableInfo<Table, dynamic> table,
    GeneratedColumn<Object> column,
  ) async {
    try {
      await m.addColumn(table, column);
    } catch (e) {
      if (!e.toString().contains('duplicate column')) rethrow;
    }
  }

  /// Creates a table, ignoring errors if it already exists from a previous partial migration.
  static Future<void> _safeCreateTable(
    Migrator m,
    TableInfo<Table, dynamic> table,
  ) async {
    try {
      await m.createTable(table);
    } catch (e) {
      if (!e.toString().contains('already exists')) rethrow;
    }
  }

  static Future<void> _dropAllUserObjects(DatabaseConnectionUser db) async {
    // 1. Drop triggers
    final triggers = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    for (final row in triggers) {
      final name = row.read<String>('name');
      try {
        await db.customStatement('DROP TRIGGER IF EXISTS "$name"');
      } catch (e) {
        log.fine('Failed to drop trigger $name: $e');
      }
    }

    // 2. Drop views
    final views = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'view' AND name NOT LIKE 'sqlite_%'",
        )
        .get();
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
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )
        .get();
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
    final remaining = await db
        .customSelect(
          "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view', 'trigger') AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    for (final row in remaining) {
      final name = row.read<String>('name');
      final type = row.read<String>('type');
      final keyword = type == 'trigger'
          ? 'TRIGGER'
          : (type == 'view' ? 'VIEW' : 'TABLE');
      try {
        await db.customStatement('DROP $keyword IF EXISTS "$name"');
      } catch (e) {
        log.warning('Failed to drop $type $name on second pass: $e');
      }
    }
  }
}

class _StoreLifecycleObserver extends WidgetsBindingObserver {
  static final _log = Logger('Store');

  final Store store;
  _StoreLifecycleObserver(this.store);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !store._isSyncing) {
      // If the WebSocket stayed connected while backgrounded, BroadcastClient
      // already handles the resume (sends a ping). Only do a full sync when
      // the connection was lost — BroadcastClient.onReconnected covers that too,
      // but _startSync is still needed when no broadcast client exists yet.
      if (store._broadcastClient?.isConnected == true) {
        _log.info('App resumed, WebSocket still connected — skipping full sync');
        return;
      }
      _log.info('App resumed, WebSocket disconnected — triggering full sync');
      store._startSync().catchError((Object error, StackTrace stackTrace) {
        _log.warning('Resume-triggered sync failed', error, stackTrace);
        return null;
      });
    }
  }
}
