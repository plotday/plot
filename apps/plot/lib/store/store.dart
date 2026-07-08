import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'dart:convert';
// Prefixed: store.dart's own [Priority] class (in priority.dart) shadows
// the scheduler one without it.
import 'package:flutter/scheduler.dart' as flutter_scheduler;
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
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

import 'open_connection_native.dart'
    if (dart.library.js_interop) 'open_connection_web.dart';
import 'package:collection/collection.dart';
import 'package:injector/injector.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:equatable/equatable.dart';
import 'package:rrule/rrule.dart';
import 'package:synchronized/synchronized.dart';
import 'package:rxdart/rxdart.dart';
import 'package:change_case/change_case.dart';

import 'package:plot/util/string.dart';
import 'package:plot/util/json_map_converter.dart';
import 'package:plot/util/string_list_converter.dart';
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
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/base.dart';
import 'package:plot/cli_args.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/analytics/profile.dart';
import 'enums.dart';
import 'attention.dart';
import 'types.dart';
import 'logging.dart';
import 'sync_entity.dart';
import 'sync_catchup_stats.dart';

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
part 'role.dart';
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
part 'reaction.dart';
part 'thread_reactions.dart';
part 'note_reactions.dart';
part 'custom_emoji.dart';
part 'thread_fts.dart';
part 'note_fts.dart';
part 'session.dart';
part 'tag.dart';
part 'thread_sub_type.dart';
part 'user_settings.dart';
part 'channel.dart';
part 'group.dart';
part 'topic.dart';
part 'team_user.dart';

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

/// UTC ISO-8601 for any [DateTime] sent to the server — a JSON body field or a
/// query param. Store-sourced DateTimes are LOCAL ([LocalDateTimeConverter.fromSql]
/// calls `.toLocal()`), so a bare `toIso8601String()` emits a timezone-naive
/// string (no trailing `Z`) that the server parses AS UTC, silently shifting the
/// value by the device's offset. This is the single source of truth for that
/// conversion: [toEncodableSyncValue] applies it to generic push bodies, and
/// hand-built bodies / query params (which never pass through that walker) call
/// it directly.
String toServerTimestamp(DateTime value) => value.toUtc().toIso8601String();

/// Recursively rewrite a sync push body into a form `jsonEncode` accepts.
///
/// Drift's default JSON serializer (used by every `DataClass.toJson`) only
/// special-cases `DateTime`; every other Dart value is emitted as-is. For
/// columns whose Dart type is not natively JSON-encodable this leaves a raw
/// object in the map, and `jsonEncode` then throws "Converting object to an
/// encodable object failed". During sync that aborts the push and silently
/// strands the row forever (`pending` is never cleared).
///
/// The known offender is [Int64Column] → [BigInt] (e.g. `thread.team_id`),
/// which has no JSON converter. We stringify any [BigInt] — lossless, and
/// Postgres binds the string straight back to its bigint/numeric column. The
/// walk also descends into maps and lists so converter-produced or
/// subclass-added nested payloads are covered, and so any future raw-typed
/// column is protected at this single sync chokepoint rather than per table.
@visibleForTesting
dynamic toEncodableSyncValue(dynamic value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is BigInt) return value.toString();
  if (value is DateTime) return toServerTimestamp(value);
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): toEncodableSyncValue(entry.value),
    };
  }
  if (value is Iterable) {
    return [for (final element in value) toEncodableSyncValue(element)];
  }
  
  // Try calling toJson if the object has one
  try {
    // ignore: avoid_dynamic_calls
    final json = (value as dynamic).toJson();
    return toEncodableSyncValue(json);
  } on NoSuchMethodError {
    // Ignore and fall through to stringification
  } catch (e, stack) {
    log.warning('toEncodableSyncValue: toJson() threw on ${value.runtimeType}', e, stack);
  }

  // Fallback: stringify to prevent jsonEncode from crashing the batch push.
  log.warning('toEncodableSyncValue: stringifying unhandled type ${value.runtimeType}');
  return value.toString();
}

/// Page size for incremental catch-up seq pulls on high-churn entities
/// (threads, notes, links, tags, schedules). The server clamps limits at
/// 1000; 500 cuts the page-loop round trips ~2.5× after a long absence and
/// changes nothing when fewer than 200 rows changed. On-demand pullTo
/// slices (feed/agenda scrolling) keep [BaseTable]'s 200 default.
const int kCatchUpPageLimit = 500;

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
      params['updated_since'] = toServerTimestamp(updatedSince);
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
  ///
  /// Serialize bounds with [toServerTimestamp]: these are query params, so they
  /// bypass the [toEncodableSyncValue] body walker, and store DateTimes are local.
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
    Map<String, dynamic>? prefetched,
    Map<String, String>? extraParams,
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
    if (extraParams != null) params.addAll(extraParams);

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
    // Fast path: a combined fetch (e.g. GET /sync/thread-detail) can supply this
    // entity's first seq-cursor page, sparing a per-entity HTTP round trip. Only
    // valid for the first page (no page cursor) of a seq pull; later pages and
    // legacy pulls fall through to HTTP. Everything after this block (cursor,
    // horizon and stamp handling) is identical either way.
    final usePrefetched = prefetched != null &&
        useSeqCursor &&
        pageSeq == null &&
        pageId == null;
    try {
      if (usePrefetched) {
        rows = (prefetched['rows'] as List<dynamic>? ?? const <dynamic>[])
            .cast<Map<String, dynamic>>();
        nextHorizon = prefetched['next_horizon']?.toString();
        final np = prefetched['next_page'];
        if (np is Map) {
          nextPage = (
            seq: np['seq'].toString(),
            id: np['id'].toString(),
          );
        }
      } else if (useSeqCursor) {
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
        // Guarantee the body is JSON-encodable before it reaches the API.
        // Drift's serializer can leave non-encodable values (e.g. a raw BigInt
        // from an Int64Column like thread.team_id) in the row; encoding those
        // throws and would strand the row in sync. See [toEncodableSyncValue].
        final body = toEncodableSyncValue(row) as Map<String, dynamic>;
        await api.post<Map<String, dynamic>>('/sync/$syncEndpoint', body: body);
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
    Roles,
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
    ThreadReactions,
    NoteReactions,
    CustomEmojis,
    Sessions,
    UserSettings,
    Channels,
    Groups,
    Topics,
    ThreadAssociations,
    TeamUsers,
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

  // Per-table push backoff. After consecutive transient push failures (server
  // timeout / 5xx / network), skip re-pushing that table until a cooldown
  // elapses, so a struggling server isn't hammered with 30s requests on every
  // save/broadcast. Reset on the first successful push. See [pushBackoffDelay].
  static final Map<String, int> _pushFailureCount = {};
  static final Map<String, DateTime> _pushBackoffUntil = {};

  static void _registerPushBackoff(String entity) {
    final count = (_pushFailureCount[entity] ?? 0) + 1;
    _pushFailureCount[entity] = count;
    _pushBackoffUntil[entity] = DateTime.now().add(pushBackoffDelay(count));
  }

  static void _resetPushBackoff(String entity) {
    _pushFailureCount.remove(entity);
    _pushBackoffUntil.remove(entity);
  }

  /// Clears the process-static push bookkeeping (in-flight completers + backoff)
  /// so tests sharing one process start clean. A push left in flight by a prior
  /// test would otherwise be awaited by the next test's push of the same table
  /// (see [_pushCompleters] in [push]) and stall it on the old store's network.
  @visibleForTesting
  static void clearPushStateForTesting() {
    _pushCompleters.clear();
    _pushFailureCount.clear();
    _pushBackoffUntil.clear();
  }

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
    _syncRetryTimer?.cancel();
    _syncRetryTimer = null;
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
        // New user OR existing user signing in on a fresh client (new browser,
        // reinstall, cleared local storage). Critical sync blocks the UI on
        // a 30s budget; everything else is deferred to background.
        //
        // INVARIANT — keep this path fast. The "existing account, fresh
        // client" case is the worst case: the entire critical pull runs
        // from `seq=0` against a populated remote. If you're tempted to
        // bump the 30s timeout, instead look at what the critical path is
        // doing and move work to the deferred phase. See
        // `SyncOrchestrator._criticalEntities` and
        // `SyncOrchestrator.syncInitialCritical` for the constraints.
        log.info("New user sync: starting connectivity check and critical sync");
        onStartStatus?.call('Welcome to Plot');
        var criticalTimedOut = false;
        try {
          await Future(() async {
            await inst._waitForNetworkConnectivity();
            log.info("New user sync: connectivity confirmed, starting critical sync");
            onStartStatus?.call('Setting things up…');
            await inst._startSyncCritical();
            log.info("New user sync: critical sync complete");
          }).timeout(const Duration(seconds: 30));
        } on TimeoutException {
          // Don't rethrow: the timeout is a soft deadline for first-render
          // data, not an auth failure. The abandoned future keeps running
          // (Dart .timeout() doesn't cancel), and the deferred sync below
          // will cover anything the critical phase didn't finish. Letting
          // this bubble up to the UserBloc would force a sign-out, which
          // doesn't fix a slow network.
          criticalTimedOut = true;
          log.warning(
            "New user critical sync exceeded 30s — proceeding with partial state; background sync will continue",
          );
          Tracker.trackError(
            'auth',
            errorType: 'TimeoutException',
            errorMessage: 'New user critical sync exceeded 30s (non-fatal)',
            context: 'sign_in_sync_timeout',
          );
        }

        // If the critical pull finished but produced no priority, the account
        // is truly empty (or sync was blocked by an auth/RLS error) — sign out
        // so the user can re-authenticate. Skip this when we timed out: the
        // abandoned future may still be paginating, and Priority.hasDefault()
        // would race against it.
        if (!criticalTimedOut && !await Priority.hasDefault()) {
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

  /// Whether a failed push should back off (and retry later) rather than fan a
  /// batch out into individual per-row pushes. True for "server is struggling"
  /// failures: a request timeout / network drop, or a 5xx / 408 / 429 from the
  /// API (a 30s statement_timeout surfaces as a 500). For these, fanning out
  /// into N individual requests that each take up to 30s only hammers a
  /// struggling server, so we leave the rows pending and retry after a cooldown.
  /// Auth (401) and permanent data errors (4xx) are handled separately and are
  /// deliberately NOT transient here.
  @visibleForTesting
  static bool isTransientPushError(dynamic error) =>
      !_isAuthError(error) && !_isPermanentError(error);

  /// Cooldown before re-pushing a table after [consecutiveFailures] consecutive
  /// transient push failures. Exponential (5s, 10s, 20s, …) capped at five
  /// minutes — mirroring [_scheduleSyncRetry] — so a struggling server gets
  /// breathing room while a long outage still retries periodically. Returns
  /// [Duration.zero] when there have been no failures.
  @visibleForTesting
  static Duration pushBackoffDelay(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return Duration.zero;
    // Clamp the shift so a huge failure count can't overflow it into nonsense.
    final exp = min(consecutiveFailures - 1, 16);
    return Duration(seconds: min(5 * (1 << exp), 300));
  }

  /// Renders a row id (stored as blob/bytes or string) for log messages.
  static String _rowIdString(dynamic id) {
    if (id == null) return '<null>';
    if (id is String) return id;
    if (id is List<int>) {
      final hex = id
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (hex.length == 32) {
        return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
            '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
            '${hex.substring(20)}';
      }
      return hex;
    }
    return id.toString();
  }

  /// One-line summary of an error for log messages — includes status code and
  /// response body for ApiException so we can see what the server actually said.
  static String _describeError(dynamic e) {
    if (e is ApiException) {
      final pg = e.pgCode != null ? ' pgCode=${e.pgCode}' : '';
      return 'status=${e.statusCode}$pg ${e.description}';
    }
    return e.toString();
  }

  /// Whether a permanent-rejection [revertOutcomeName] (a [_RevertOutcome]
  /// name) warrants an error-tracking report.
  ///
  /// `absentOnServer` is the EXPECTED transient case: the row is an unsynced
  /// create the server hasn't seen yet — almost always because a parent row (a
  /// note's thread, which files `thread_priority`) hasn't been pushed in this
  /// cycle, so `/sync/<endpoint>` fails `assertThreadAccess` with a 403. The
  /// row is kept `pending` and the next sync retries; once the parent lands it
  /// self-heals with no data loss. Capturing it floods error tracking with
  /// noise for a self-correcting condition (PostHog issue 019f0508), so we
  /// don't report it. (The known *non*-transient variant — a published note
  /// stranded on a still-draft thread — loops forever and is prevented at the
  /// source by `_buildDraftFilter`, not by reporting after the fact.)
  ///
  /// `reverted` (we overwrote the user's local edit with the server's version)
  /// and `fetchFailed` (we couldn't determine the remote state) are genuine
  /// concerns worth surfacing.
  @visibleForTesting
  static bool shouldReportRevertOutcome(String revertOutcomeName) =>
      revertOutcomeName != _RevertOutcome.absentOnServer.name;

  /// Report an unexpected sync-push failure to PostHog error tracking with the
  /// structured context needed to debug it.
  ///
  /// Only failures that discard or strand a local change reach here — a
  /// permanent server rejection (the local edit is reverted to remote or kept
  /// pending forever) or a row we can't even serialize to push. Transient
  /// network errors and expected auth sign-outs are handled elsewhere and are
  /// deliberately not reported.
  ///
  /// [reason] is the human-readable failure class and, together with the
  /// endpoint and error description, forms the exception message PostHog groups
  /// on — keep it stable per bug (no row ids or counts). Per-occurrence detail
  /// (row id, status, pg code) goes into [properties] so it stays filterable
  /// without fragmenting the issue.
  static void _reportSyncFailure(
    String reason, {
    required String table,
    required String endpoint,
    required String outcome,
    required Object error,
    required StackTrace stackTrace,
    String? rowId,
    Map<String, dynamic> extraProperties = const {},
  }) {
    final api = error is ApiException ? error : null;
    Tracker.captureException(
      StateError('$reason ($endpoint): ${_describeError(error)}'),
      stackTrace,
      properties: {
        'sync_table': table,
        'sync_endpoint': endpoint,
        'sync_row_id': ?rowId,
        'sync_outcome': outcome,
        if (api != null) 'http_status': api.statusCode,
        if (api?.pgCode != null) 'pg_code': api!.pgCode,
        if (api?.code != null) 'error_code': api!.code,
        ...extraProperties,
      },
    );
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
  static Timer? _syncRetryTimer;

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

    _scheduleSyncRetry();
  }

  /// Schedule a future `_startSync` with exponential backoff (capped at 5
  /// minutes). Used when a sync attempt fails for a transient reason: a
  /// missing auth token (but the session isn't definitively dead), or a
  /// network/5xx error from the API. Without this, recovery depends on a
  /// lifecycle/connectivity event firing — so an API outage that lasts past
  /// startup leaves the client stuck on stale data with no way back.
  static void _scheduleSyncRetry() {
    _syncRetryCount++;
    final delaySec = min(30 * _syncRetryCount, 300);
    log.warning(
      "Sync error (attempt $_syncRetryCount), retrying in ${delaySec}s",
    );

    _syncRetryTimer?.cancel();
    if (Injector.appInstance.exists<Store>()) {
      _syncRetryTimer = Timer(Duration(seconds: delaySec), () {
        if (Injector.appInstance.exists<Store>()) {
          Store.get._startSync(trigger: 'retry').catchError((
            Object e,
            StackTrace s,
          ) {
            log.warning("Retry sync failed", e, s);
          });
        }
      });
    }
  }

  /// Reset retry tracking after a successful sync.
  static void _resetSyncRetry() {
    if (_syncRetryCount > 0) {
      log.info("Sync recovered after $_syncRetryCount failed attempts");
    }
    _syncRetryCount = 0;
    _syncRetryTimer?.cancel();
    _syncRetryTimer = null;
  }

  BroadcastClient? _broadcastClient;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  _StoreLifecycleObserver? _lifecycleObserver;
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;
  bool _hasSyncedSuccessfully = false;
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
    // Fire and forget push through orchestrator for dependency awareness.
    //
    // Run the push in the root zone so it escapes any active transaction
    // zone. When `save()` is called inside `Store.transaction(...)`, drift
    // routes DB operations to the transaction executor via a Zone. A
    // fire-and-forget push started in that zone captures it, so the push's
    // own writes (the claim `UPDATE ... RETURNING` and the `pending` clear)
    // execute *after* the transaction body returns and the executor is
    // closed — throwing "Transaction used after it was closed". Hopping to
    // the root zone routes those writes to the main executor instead, where
    // they serialize behind the open transaction and therefore observe its
    // committed rows.
    final entity = SyncOrchestrator.getEntityByTableName(baseTable.table);
    Zone.root.run(() {
      if (entity != null) {
        SyncOrchestrator.instance.push(entity);
      } else {
        // Fallback to direct push for entities not in orchestrator
        push(table, baseTable);
      }
    });
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

    // Back off a table whose server side is failing transiently (timeout/5xx):
    // skip re-pushing until the cooldown elapses rather than retrying on every
    // save/broadcast and hammering a struggling server. Reset on next success.
    final backoffUntil = _pushBackoffUntil[entity];
    if (backoffUntil != null && DateTime.now().isBefore(backoffUntil)) {
      log.fine(
        "Skipping push for $entity — backing off until "
        "${backoffUntil.toIso8601String()}",
      );
      return false;
    }

    // Start new push
    final completer = Completer<bool>();
    _pushCompleters[entity] = completer;
    final sw = Stopwatch()..start();

    try {
      // First fetch rows with pending changes and mark them as sync-in-progress.
      // Exclude draft rows and rows belonging to draft threads — they shouldn't
      // be pushed until published.
      final draftFilter = _buildDraftFilter(table);
      final holdFilter = _buildHoldFilter(table);
      final claimSw = Stopwatch()..start();
      final List<QueryRow> pendingRows = await customWriteReturning(
        'UPDATE ${table.actualTableName} SET pending = pending | 1 WHERE pending IS NOT NULL$draftFilter$holdFilter RETURNING *',
        updates: {table},
      );
      final claimMs = claimSw.elapsedMilliseconds;

      var success = false;
      if (pendingRows.isEmpty) {
        success = true;
        if (syncPerfLog) {
          log.info(
            'Store.push ${baseTable.fullName}: ${sw.elapsedMilliseconds}ms '
            '(claim ${claimMs}ms, no pending rows)',
          );
        }
      } else {
        final pendingIds = pendingRows
            .map((r) => _rowIdString(r.data['id']))
            .toList();
        log.info(
          "Pushing ${pendingRows.length} ${baseTable.name} rows: $pendingIds",
        );

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
          log.info(
            "Batch push succeeded for ${pendingRows.length} ${baseTable.name} rows",
          );
        } catch (e, trace) {
          // A transient batch failure (request timeout / 5xx — a 30s server
          // statement_timeout surfaces as a 500) means the server is
          // struggling. Fanning out into N individual requests that each take
          // up to 30s only hammers it harder, so skip the fan-out and let the
          // per-table cooldown back it off; the rows stay pending for retry.
          final batchTransient = Store.isTransientPushError(e);
          log.warning(
            batchTransient
                ? "Transient batch push failure for ${baseTable.name} "
                    "(${e.runtimeType}: ${_describeError(e)}); backing off "
                    "instead of individual retries"
                : "Batch push failed for ${baseTable.name} "
                    "(${e.runtimeType}: ${_describeError(e)}), "
                    "falling back to individual pushes",
            e,
            trace,
          );

          // Step 3b: On a non-transient (permanent) batch failure, try the
          // rows individually to isolate the specific bad row. A transient
          // failure iterates an empty list — no fan-out.
          for (final row in (batchTransient ? const <QueryRow>[] : pendingRows)) {
            final rowId = _rowIdString(row.data['id']);
            try {
              final data = await table.map(row.data);
              try {
                log.info(
                  "Pushing individual ${baseTable.name} row $rowId",
                );
                await baseTable.put([baseTable.toBase(data)]);
                success = true;
                // set pending = NULL for this row
                await customUpdate(
                  'UPDATE ${table.actualTableName} SET pending = NULL WHERE id = ?',
                  variables: [Variable(row.data['id'])],
                  updates: {table},
                );
                log.info(
                  "Individual push succeeded for ${baseTable.name} row $rowId",
                );
              } catch (e, stackTrace) {
                if (Store._isAuthError(e)) {
                  log.warning(
                    "Auth error pushing ${baseTable.name} row $rowId — "
                    "triggering sign-out",
                  );
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
                  log.warning(
                    "Permanent error pushing ${baseTable.name} row $rowId: "
                    "${_describeError(e)} — attempting revert to remote",
                    e,
                    stackTrace,
                  );

                  final outcome = await _revertToRemote(
                    baseTable,
                    table,
                    baseTable.toBase(data),
                  );

                  log.warning(
                    "Revert outcome for ${baseTable.name} row $rowId: "
                    "${outcome.name}",
                  );

                  // Report only the outcomes that discard or strand a local
                  // change: `reverted` (we overwrote the user's edit) and
                  // `fetchFailed` (unknown remote state). `absentOnServer` is
                  // the expected transient case — an unsynced create whose
                  // parent row hasn't pushed yet — which we keep pending and
                  // retry; it self-heals next cycle, so reporting it is just
                  // error-tracking noise (see [shouldReportRevertOutcome]).
                  if (shouldReportRevertOutcome(outcome.name)) {
                    _reportSyncFailure(
                      'Permanent sync push rejected',
                      table: baseTable.name,
                      endpoint: baseTable.syncEndpoint,
                      rowId: rowId,
                      outcome: outcome.name,
                      error: e,
                      stackTrace: stackTrace,
                    );
                  }

                  if (outcome == _RevertOutcome.reverted) {
                    await customUpdate(
                      'UPDATE ${table.actualTableName} SET pending = NULL WHERE id = ?',
                      variables: [Variable(row.data['id'])],
                      updates: {table},
                    );
                  }
                  // else absentOnServer / fetchFailed: leave `pending` set —
                  // the row stays in the queue and the next push retries.
                  // Don't set success = true (this wasn't a successful push).
                } else {
                  // Transient error - log and continue
                  log.warning(
                    "Transient error pushing ${baseTable.name} row $rowId "
                    "to ${baseTable.syncEndpoint}: "
                    "${e.runtimeType}: ${_describeError(e)}",
                    e,
                    stackTrace,
                  );
                }
              }
            } catch (e, stackTrace) {
              // We couldn't even serialize this row to push it — it will stay
              // pending and never sync. That's an unexpected bug (e.g. an
              // unencodable value reached the row), so report it with context.
              _reportSyncFailure(
                'Sync row serialize failed',
                table: baseTable.name,
                endpoint: baseTable.syncEndpoint,
                rowId: rowId,
                outcome: 'serialize_error',
                error: e,
                stackTrace: stackTrace,
              );
              log.warning(
                "Error parsing ${baseTable.name} row $rowId "
                "(${jsonEncode(row.data)})",
                e,
                stackTrace,
              );
            }
          }
        }

        if (syncPerfLog) {
          log.info(
            'Store.push ${baseTable.fullName}: ${sw.elapsedMilliseconds}ms '
            '(claim ${claimMs}ms, rows ${pendingRows.length}, '
            '${success ? "ok" : "failed"})',
          );
        }
      }

      // Drive the per-table backoff: a clean push resets it; a failed one
      // (transient batch backoff, or rows left pending) grows the cooldown so
      // the next attempt waits instead of hammering a struggling server.
      if (success) {
        _resetPushBackoff(entity);
      } else {
        _registerPushBackoff(entity);
      }

      completer.complete(success);
      return success;
    } catch (e, trace) {
      log.warning("Push failed for ${baseTable.table}", e, trace);
      _registerPushBackoff(entity);
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
  ///
  /// `notes` has BOTH a `draft` column and a `thread_id`: a published note
  /// (draft = 0) can sit on a thread that is still a local draft (draft = 1)
  /// if a late draft-save flips the thread back after publish. Such a note
  /// must NOT be pushed ahead of its thread — the thread (and its
  /// `thread_priority` row) doesn't exist server-side yet, so `/sync/notes`
  /// hard-fails `assertThreadAccess` with a 403, reverts to `absentOnServer`,
  /// and the note loops forever. So we combine both filters rather than
  /// returning on the first match: a note is pushable only when it is
  /// published AND its thread is not a local draft.
  /// IDs (32-char lowercase hex, no dashes) of the note/thread currently in a
  /// 5-second "undo send" window (see `PendingSend`). The rows are saved
  /// NON-draft so they appear in lists/feeds/search immediately, but their
  /// remote push is held until the window elapses (or the app closes / signs
  /// out). Mirrors the role of [_buildDraftFilter]: held rows stay `pending`
  /// but are excluded from the push claim until released, so a stray sync can't
  /// send a note before its undo window completes. At most one of each is set
  /// (sends are one-at-a-time), but a Set keeps the brief commit-prior overlap
  /// safe.
  static final Set<String> pushHeldNoteIds = {};
  static final Set<String> pushHeldThreadIds = {};

  /// SQL fragment excluding [pushHeldNoteIds] / [pushHeldThreadIds] from a push
  /// claim. Covers the note/thread tables and the tag/reaction tables that
  /// share their parent's id (pushing a child ahead of a held parent would
  /// 404 server-side). Returns '' when nothing is held.
  static String _buildHoldFilter(TableInfo<Table, DataClass> table) {
    final name = table.actualTableName;
    Set<String>? held;
    if (name == 'notes' || name == 'note_tags' || name == 'note_reactions') {
      held = pushHeldNoteIds;
    } else if (name == 'threads' ||
        name == 'thread_tags' ||
        name == 'thread_reactions') {
      held = pushHeldThreadIds;
    }
    if (held == null || held.isEmpty) return '';
    final list = held.map((h) => "x'$h'").join(', ');
    return ' AND id NOT IN ($list)';
  }

  static String _buildDraftFilter(TableInfo<Table, DataClass> table) {
    final columns = table.$columns;
    final name = table.actualTableName;

    final clauses = <String>[];

    // Tables with their own draft column (threads, notes)
    if (columns.any((c) => c.$name == 'draft')) {
      clauses.add('draft = 0');
    }

    // Tables with thread_id FK (notes, schedules, links, etc.) — don't push a
    // row whose parent thread is still a local draft (and thus unpushed).
    if (columns.any((c) => c.$name == 'thread_id')) {
      clauses.add('(thread_id IS NULL OR thread_id NOT IN'
          ' (SELECT id FROM threads WHERE draft = 1))');
    }

    if (clauses.isNotEmpty) {
      return ' AND ${clauses.join(' AND ')}';
    }

    // Tag tables that share id with their parent
    // note_tags / note_reactions share the parent note's id, so exclude any
    // whose note is a draft — covers a reaction added during a note's undo-send
    // window that is then undone (the note flips to draft + archived).
    if (name == 'note_tags' || name == 'note_reactions') {
      return ' AND id NOT IN (SELECT id FROM notes WHERE draft = 1)';
    }
    if (name == 'thread_tags') {
      return ' AND id NOT IN (SELECT id FROM threads WHERE draft = 1)';
    }

    return '';
  }

  /// Test-only access to [_buildDraftFilter].
  @visibleForTesting
  static String buildDraftFilter(TableInfo<Table, DataClass> table) =>
      _buildDraftFilter(table);

  /// True once [entity] has completed a pull — a seq horizon or legacy
  /// pulledAt stamp exists. Mirrors the "initialized" check inside [pull].
  Future<bool> isEntityInitialized(String entity) async {
    final state = await (select(syncStates)
          ..where((row) => row.entity.equals(entity)))
        .getSingleOrNull();
    return state?.lastHorizon != null || state?.pulledAt != null;
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
    // First seq-cursor page supplied by a combined fetch (e.g. the
    // /sync/thread-detail envelope for this entity). When non-null its rows seed
    // the first page instead of a per-entity HTTP request; any later pages
    // (rare) and all later pulls fetch over HTTP. Null restores the original
    // behaviour exactly — the automatic fallback when the combined endpoint is
    // unavailable. See [Note.pullForActivity].
    Map<String, dynamic>? prefetched,
    // Extra server query params merged into every page request (e.g.
    // `{'self': 'true'}` to restrict /sync/actors to the user's own actors).
    Map<String, String>? extraParams,
    // When false, the shared per-entity seq cursor (`syncStates`) is NOT
    // advanced after this pull. Required for FILTERED bounded pulls (e.g. the
    // self-only actor pull): they return a subset, so stamping the cursor would
    // make the later full pull skip every unfetched row below that horizon.
    bool stampCursor = true,
    // Stop after at most this many pages instead of draining the whole table.
    // For bounded critical pulls that must NOT depend on a server-side filter
    // (e.g. the self-actor pull, in case the `self=true` filter isn't deployed
    // yet): one page of the seq-ascending cursor still contains the user's own
    // actors (lowest seq, created at signup). Pair with `stampCursor: false`
    // so the early stop never advances the cursor past unfetched rows.
    int? maxPages,
  }) async {
    final entity = baseTable.fullName;
    final sw = Stopwatch()..start();
    var httpMs = 0;
    var dbMs = 0;
    var pages = 0;

    final syncStateSw = Stopwatch()..start();
    final syncState = await (select(
      syncStates,
    )..where((row) => row.entity.equals(entity))).getSingleOrNull();
    dbMs += syncStateSw.elapsedMilliseconds;

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
    // When a row in this pull fails to deserialize, we cannot safely
    // advance the seq cursor: doing so would skip the row forever (the
    // server only re-emits rows with `seq >= last_horizon`). The May 2026
    // `revoked` field bug — client expected non-null `bool revoked`, prod
    // briefly served threads without it — silently dropped every thread
    // row while letting the cursor sail past, stranding affected users
    // with zero threads even after the parsing fix landed. Track parse
    // failures here, suppress the horizon commit at the end, and let the
    // next sync re-pull from the prior cursor.
    var rowParseFailed = false;
    // Some processPulledRows overrides (e.g. SchedulesBase,
    // ThreadAssociationsBase) drop rows whose local copy has an in-flight
    // `pending` edit, to avoid clobbering the user's unsent change. Those
    // rows must not count toward the cursor advance below: the server only
    // re-emits rows with `seq >= last_horizon`, so once the cursor passes a
    // dropped row's seq it is never resent — the update would be lost, not
    // just deferred to "the next pull" as the drop sites assume.
    var rowsDroppedForPending = false;

    do {
      pages++;
      final httpSw = Stopwatch()..start();
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
        // Only the first page can come from the prefetched envelope; any
        // subsequent pages (pageSeq set) fetch over HTTP.
        prefetched: pages == 1 ? prefetched : null,
        extraParams: extraParams,
      );
      httpMs += httpSw.elapsedMilliseconds;
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
          rowParseFailed = true;
          log.severe(
            "Error parsing row from ${baseTable.table} — aborting cursor advance for this pull. Row: ${jsonEncode(r, toEncodable: (o) => o.toString())}",
            e,
            stackTrace,
          );
          // The root-logger forward in main.dart ships warning+ as
          // PostHog *events*; captureException is what lands them in
          // PostHog error tracking (grouped, with a stack analysis).
          // Repeat-parse failures across pulls would otherwise blend
          // into the event stream and be easy to miss.
          Tracker.captureException(e, stackTrace);
          return [];
        }
      });

      final writeSw = Stopwatch()..start();
      // Allow base table to merge with local pending state
      final storeRowsList = storeRows.toList();
      final processedRows = await baseTable.processPulledRows(
        this,
        storeRowsList,
      );
      if (processedRows.length < storeRowsList.length) {
        rowsDroppedForPending = true;
        log.fine(
          "${baseTable.table}: processPulledRows dropped "
          "${storeRowsList.length - processedRows.length} row(s) with "
          "in-flight local edits — suppressing cursor advance for this pull",
        );
      }

      // Skip opening a write transaction when there's nothing to write.
      // Drift's `batch()` acquires an exclusive lock regardless of payload,
      // and a no-op pull (server returned zero rows) would otherwise serialise
      // against concurrent watch-stream reads for no benefit.
      if (processedRows.isNotEmpty) {
        await batch((batch) {
          // Use insertOrReplace mode to ensure null values are explicitly set.
          // - insertAllOnConflictUpdate uses toColumns(true) which treats null as
          //   "don't update this column" - causing unarchived items to stay archived
          // - insertOrReplace deletes and re-inserts the row, ensuring all columns
          //   including nulls are set correctly
          batch.insertAll(table, processedRows, mode: InsertMode.insertOrReplace);
        });
      }
      dbMs += writeSw.elapsedMilliseconds;

      totalRows += baseRows.length;
      // If any row in this batch failed to parse, or was dropped for an
      // in-flight local edit, drop out of the pagination loop and skip the
      // horizon commit below. Continuing would advance the cursor past rows
      // that were never actually written. The current `syncState` cursor
      // stays put; the next sync re-fetches from the same place.
      if (rowParseFailed || rowsDroppedForPending) break;
    } while (more && (maxPages == null || pages < maxPages));

    if (totalRows > 0) {
      log.fine("Synced ${baseTable.name}: $totalRows rows");
    }

    // Persist the new horizon. Also stamp `pulledAt` to now() so legacy
    // code paths that check `pulledAt != null` to detect "entity is
    // initialized" continue to work during the expand-contract rollout.
    //
    // Skip the entire stamp when a row failed to parse, or was dropped for
    // an in-flight local edit: advancing `last_horizon` (or stamping
    // `pulledAt` on initial sync, which also gates the "initialized" check
    // on the next pull) would lock us past rows that were never actually
    // written. Leaving syncStates untouched lets the next sync attempt
    // re-pull from the same cursor — with, hopefully, a fixed deserializer
    // or a cleared local `pending` flag.
    final shouldStamp =
        stampCursor &&
        !rowParseFailed &&
        !rowsDroppedForPending &&
        (finalHorizon != null ||
            (initial && baseTable.filterName == null));
    var stamped = false;
    if (shouldStamp) {
      final horizonInt = finalHorizon != null
          ? int.tryParse(finalHorizon)
          : null;
      // Short-circuit no-op pulls: when the cursor didn't advance and the
      // entity is already initialized (`pulledAt` non-null), there's
      // nothing meaningful to record. Skipping the upsert avoids
      // serialising a write transaction against concurrent watch streams,
      // which is the dominant per-entity cost during an idle-startup
      // syncAll where ~16 entities all return zero rows.
      final cursorUnchanged =
          horizonInt != null && horizonInt == syncState?.lastHorizon;
      final alreadyInitialized = syncState?.pulledAt != null;
      if (!cursorUnchanged || !alreadyInitialized) {
        final stampSw = Stopwatch()..start();
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
        dbMs += stampSw.elapsedMilliseconds;
        stamped = true;
      }
    }

    if (syncPerfLog) {
      log.info(
        'Store.pull ${baseTable.fullName}: ${sw.elapsedMilliseconds}ms '
        '(http ${httpMs}ms, db ${dbMs}ms, pages $pages, rows $totalRows'
        '${stamped ? ", stamped" : ""})',
      );
    }

    SyncCatchupStats.current?.recordPull(
      baseTable.fullName,
      sw.elapsedMilliseconds,
      pages,
      totalRows,
    );

    // No caller reads pull()'s return value (all callsites await without
    // assigning), so skip the trailing `sync_states` re-read that this
    // method used to perform to compute it. Keeping the signature for
    // back-compat with existing callers.
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
    // See `pull` above for the rationale. Skip the "pulled" stamp if a
    // row failed to deserialize so the next attempt retries from scratch
    // (this method short-circuits on `pulledAt != null`).
    var rowParseFailed = false;

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
          rowParseFailed = true;
          log.severe(
            "Error parsing archived row from ${baseTable.table} — aborting pullArchived. Row: ${jsonEncode(r, toEncodable: (o) => o.toString())}",
            e,
            stackTrace,
          );
          Tracker.captureException(e, stackTrace);
          return [];
        }
      });

      await batch((batch) {
        batch.insertAll(table, storeRows, mode: InsertMode.insertOrReplace);
      });
      totalRows += baseRows.length;
      if (rowParseFailed) break;
    } while (more);

    // Mark as pulled — unless a row failed to deserialize, in which case
    // we want the next call to retry from scratch.
    if (rowParseFailed) {
      log.severe(
        "pullArchived(${baseTable.table}) aborted with $totalRows rows; not stamping pulled_at so retry is possible",
      );
      return;
    }
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

      var pullToParseFailed = false;
      final storeRows = baseRows.expand<Insertable<DataClass>>((r) {
        try {
          return [baseTable.fromBase(r)];
        } catch (e, stackTrace) {
          pullToParseFailed = true;
          log.severe(
            "Error parsing row from ${baseTable.table} — aborting pullTo cursor advance. Row: ${jsonEncode(r, toEncodable: (o) => o.toString())}",
            e,
            stackTrace,
          );
          Tracker.captureException(e, stackTrace);
          return [];
        }
      });

      // Allow base table to merge with local pending state
      final storeRowsList = storeRows.toList();
      final processedRows = await baseTable.processPulledRows(
        this,
        storeRowsList,
      );
      final pullToRowsDroppedForPending =
          processedRows.length < storeRowsList.length;
      if (pullToRowsDroppedForPending) {
        log.fine(
          "${baseTable.table}: processPulledRows dropped "
          "${storeRowsList.length - processedRows.length} row(s) with "
          "in-flight local edits — suppressing pullTo cursor advance",
        );
      }

      await batch((batch) {
        // Use insertOrReplace mode to ensure null values are explicitly set.
        // - insertAllOnConflictUpdate uses toColumns(true) which treats null as
        //   "don't update this column" - causing unarchived items to stay archived
        // - insertOrReplace deletes and re-inserts the row, ensuring all columns
        //   including nulls are set correctly
        batch.insertAll(table, processedRows, mode: InsertMode.insertOrReplace);
      });

      totalRows += baseRows.length;

      // Skip the cursor + noMore stamp when a row failed to deserialize, or
      // was dropped for an in-flight local edit. pullTo paginates by the
      // `last` column derived from `baseRows.last`, which would advance past
      // rows that were never actually written and strand them. Leaving the
      // sync state untouched lets the next pull retry from the same place.
      if (pullToParseFailed || pullToRowsDroppedForPending) {
        completer.complete(null);
        return null;
      }

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

  /// Coalesces overlapping catch-up triggers (resume + reconnect firing
  /// within milliseconds) onto one sweep. The per-entity _pullDirty
  /// machinery still covers broadcast-driven changes that land mid-pull.
  final _catchUpRunner = CoalescedRunner();

  Future<void> _syncAll({required String trigger}) =>
      _catchUpRunner.run(() => _syncAllInner(trigger));

  /// Public entry for externally-triggered catch-up syncs (e.g. FCM push
  /// wake). Routes through the same coalescing and telemetry as every other
  /// catch-up trigger — a push arriving while a sweep is in flight joins it
  /// instead of running a second unguarded sweep (which would also corrupt
  /// the in-flight sync_catchup stats).
  Future<void> catchUpSync({required String trigger}) {
    if (_closing) return Future.value();
    return _syncAll(trigger: trigger);
  }

  Future<void> _syncAllInner(String trigger) async {
    SyncCatchupStats.current = SyncCatchupStats(trigger);
    try {
      // Snapshot the count before sync. SyncOrchestrator swallows auth errors
      // (treats them as expected) so syncAll() can return normally even when every
      // operation got a 401. Only reset if no new auth failures occurred during
      // this sync — otherwise we'd falsely log "recovered" and reset the backoff.
      final countBefore = _syncRetryCount;
      try {
        // Use orchestrator for dependency-aware sync
        // This pulls all entities (parents→children), then pushes all (children→parents)
        await SyncOrchestrator.instance.syncAll();
        _hasSyncedSuccessfully = true;
        if (_syncRetryCount == countBefore) {
          _resetSyncRetry();
        }
      } catch (e, stackTrace) {
        // Mark the sweep as failed so the `sync_catchup` event's `ok` flag
        // reflects it — a failed sweep (auth/RLS/transient) often bails out
        // early, and its short total_ms would otherwise skew the latency
        // dashboard optimistically alongside genuinely fast successful runs.
        SyncCatchupStats.current?.failed = true;
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
        } else {
          // Transient (network/5xx) failure — schedule a retry so we recover
          // without needing a lifecycle or connectivity event to fire. The
          // WebSocket-reconnect path also kicks a sync, but it only helps if
          // the socket itself reconnected; an HTTP-only outage (socket up,
          // 5xx on /sync/*) wouldn't trigger anything.
          _scheduleSyncRetry();
        }
        log.warning("Error during _syncAll", e, stackTrace);
      }
    } finally {
      final stats = SyncCatchupStats.current;
      SyncCatchupStats.current = null;
      if (stats != null) {
        unawaited(Tracker.track('sync_catchup', stats.finish()));
      }
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
      // If the startup sync hasn't run or hasn't succeeded yet (e.g. API was
      // unreachable at launch), have the WebSocket's first connect trigger
      // the catch-up too. When a sync is currently in flight we skip — that
      // sync will catch us up itself.
      needsCatchUpOnFirstConnect: () =>
          !_isSyncing && !_hasSyncedSuccessfully,
    );
  }

  void _handleReconnected() {
    if (_closing) return;
    log.info('WebSocket reconnected, triggering catch-up sync');
    _syncAll(trigger: 'reconnect').catchError((
      Object error,
      StackTrace stackTrace,
    ) {
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
          _scheduleSyncRetry();
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
      _resetSyncRetry();
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

  Future<void> _startSync({required String trigger}) async {
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
          _scheduleSyncRetry();
        }
        return;
      }

      // Subscribe to WebSocket FIRST, buffering messages during sync
      _isBufferingBroadcasts = true;
      _bufferedTables.clear();
      await _subscribeToUpdates();

      await _syncAll(trigger: trigger);
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
        await _startSync(trigger: 'startup');
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
          _startSync(trigger: 'connectivity').catchError((
            Object error,
            StackTrace stackTrace,
          ) {
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

  /// Test-only constructor that opens the full schema against an injected
  /// executor (e.g. `NativeDatabase.memory()`). Lets store-layer queries be
  /// exercised end-to-end in unit tests without the production file/profile
  /// machinery.
  @visibleForTesting
  Store.forTesting(super.executor);

  // Platform-split connection. Native opens with WAL + a read pool so the
  // focus-switch query burst doesn't serialize behind sync-write commits;
  // web keeps the original drift_flutter wasm setup. See
  // open_connection_native.dart for the full rationale.
  Store._(User user) : super(openPlotConnection(_databaseName(user.id)));

  static String _databaseName(String userId) {
    final profile = CliArgs.profile;
    if (profile != null) {
      return 'plot-$userId-$profile';
    }
    return 'plot-$userId';
  }

  @override
  int get schemaVersion => 378;

  /// Schema-drift probes run in `beforeOpen` (one column-set per
  /// recently-changed table). A stale on-disk schema — e.g. web OPFS surviving
  /// "Clear site data", which passes `CREATE TABLE IF NOT EXISTS` migration but
  /// is missing newer columns — throws on the probe, triggering a full rebuild.
  ///
  /// CRITICAL: only probe columns that EXIST in the current Drift schema. Never
  /// probe a column that a migration dropped (e.g. the removed `priorities.root`
  /// — dropped in v373): the on-disk schema correctly lacks it, so the probe
  /// would throw on *every* launch and rebuild the DB every time — wiping local
  /// data and forcing a full re-sync each start. `priority_schema_probe_test`
  /// guards this by running every probe against a freshly-created schema.
  static const schemaProbes = [
    'SELECT id, archived_at, created_at, icon, role_id, is_inbox FROM priorities LIMIT 0',
    'SELECT id, updated_at, multiple_instances, is_builtin FROM twist_instances LIMIT 0',
    'SELECT id, updated_at FROM groups LIMIT 0',
    'SELECT id, topic, groups FROM threads LIMIT 0',
  ];

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
        for (final sql in schemaProbes) {
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

  /// Advance the notification high-water mark for the focus containing the
  /// given priority. This prevents stale notifications from being shown
  /// locally or fetched from the server.
  ///
  /// The watermark is stored on the first-level focus (direct child of root) —
  /// the unit notifications are grouped by — so a nested priority resolves to
  /// its focus ancestor before stamping. This keeps the client write target
  /// consistent with the server (which stamps the focus) and the read path
  /// (which reads the focus watermark).
  Future<void> updateNotificationWatermark(Uuid priorityId) async {
    final priority = await (select(priorities)
          ..where((p) => p.id.equals(priorityId.toBytes())))
        .getSingleOrNull();

    if (priority == null) return;

    final focus = await _firstLevelFocusFor(priority);
    if (focus == null) return;

    final now = DateTime.now();
    final current = focus.notificationClearedAt;

    // Only advance the timestamp (handles offline/sync edge cases).
    if (current == null || now.isAfter(current)) {
      await (update(priorities)
            ..where((p) => p.id.equals(focus.id.toBytes())))
          .write(PrioritiesCompanion(notificationClearedAt: Value(now)));
    }
  }

  /// Resolve the first-level focus that contains the given priority. Flat/role
  /// model: threads are filed directly in a focus, so the first-level focus is
  /// simply the priority itself (every focus, the Inbox included, is its own
  /// first-level focus).
  Future<PriorityRow?> _firstLevelFocusFor(PriorityRow priority) async {
    return priority;
  }

  /// Performs a full re-sync from the server without losing local data.
  ///
  /// Marks all existing rows with a sentinel updatedAt (epoch), clears sync
  /// state, re-pulls everything from the server (which overwrites the sentinel
  /// on items that still exist), then deletes orphaned rows that still have
  /// the sentinel. Regular sync is suspended during the entire operation.
  Future<void> fullResync() async {
    // Wait for any in-progress sync to finish before we stamp the resync
    // sentinel below. This must drain BOTH _isSyncing (set by regular
    // startup/connectivity syncs) and _catchUpRunner (used by the reconnect
    // and app-resume triggers, which never set _isSyncing). A sweep already
    // in flight when the sentinel stamp runs pulls using its own pre-clear
    // sync-state cursors, so it won't refresh sentinels on rows it doesn't
    // touch — joining it (instead of waiting for it to finish) would make
    // step 5 below delete every row that sweep didn't happen to touch. Loop
    // because another sync/sweep can start again in the gap between the two
    // waits.
    while (_isSyncing || _catchUpRunner.isRunning) {
      // Wait briefly for any in-progress regular sync to finish (up to 5s)
      for (var i = 0; i < 50 && _isSyncing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_isSyncing) throw StateError('A sync is already in progress');
      await _catchUpRunner.waitIdle();
    }
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
      // Drain again right before our sweep: a runner-only sweep (push-wake /
      // reconnect) that started during steps 1-3 read PRE-clear cursors, so
      // joining it would leave sentinels unrefreshed and step 5 would delete
      // live rows. This waitIdle → _syncAll continuation has no interleave
      // point, and any sweep starting after step 3's clear pulls from
      // scratch, so joining one of those is safe.
      await _catchUpRunner.waitIdle();
      await _syncAll(trigger: 'resync');

      // 4b. Pull first page of activity feed and agenda (global, no priority filter)
      // This ensures recent/relevant threads survive orphan deletion.
      await Thread.pullActivityFeed(null);
      await Thread.pullAgenda(null);

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
      // Legacy `urgency` column on threads — dropped at v336 along with the
      // server-side rename to thread_state. Add it as a no-op so older
      // schemas catch up to the (then-current) v273 shape before later
      // migrations drop it.
      await _safeCustomStatement(
        m,
        'ALTER TABLE threads ADD COLUMN urgency TEXT',
      );
    }
    if (from < 274) {
      // Legacy `see_within_requests` / `see_within_updates` columns —
      // collapsed to a single `see_within` at v337. Added here as raw
      // SQL no-ops so older schemas can catch up; v337 then rebuilds the
      // table to drop them.
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN see_within_requests TEXT',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN see_within_updates TEXT',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN see_within_requests_set BOOLEAN NOT NULL DEFAULT 0',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN see_within_updates_set BOOLEAN NOT NULL DEFAULT 0',
      );
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
      // Legacy `outstanding_tasks` column on schedules — dropped at v336
      // when per-user state moved off `schedule`. Added as a no-op so older
      // schemas catch up to the (then-current) v277 shape.
      await _safeCustomStatement(
        m,
        'ALTER TABLE schedules ADD COLUMN outstanding_tasks BOOLEAN NOT NULL DEFAULT 0',
      );
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
      // server schema. priorities.team_id was dropped again at v353 (focuses
      // are team-agnostic) so the Drift table no longer declares it — do the
      // rename via raw SQL (the column accessor no longer exists) so users on
      // this path keep their data until the v353 drop removes the column.
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities RENAME COLUMN organization_id TO team_id',
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
      // priority with contacts/groups/invite emails. These columns were
      // dropped again at v353 (focuses are now team-agnostic), so the Drift
      // table no longer declares them — add them here via raw SQL (the
      // column accessors no longer exist) so a user migrating through this
      // version still rebuilds cleanly before the v353 drop removes them.
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN default_contacts TEXT',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN default_groups TEXT',
      );
      await _safeCustomStatement(
        m,
        'ALTER TABLE priorities ADD COLUMN default_invite_emails TEXT',
      );
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
    if (from < 329) {
      // Explicit vs auto-start distinction: paused explicit sessions are
      // revivable, 5-minute distraction handoffs are not. Defaults to
      // true so any pre-upgrade in-flight session is treated as explicit
      // (the safer choice — the user can Stop it).
      await _safeAddColumn(m, sessions, sessions.explicit);
    }
    if (from < 330) {
      // One-time cleanup for `priority_block.duration` residue left by
      // the old session-close write-back path. That path stored each
      // closed session's remaining time on the priority's "current"
      // block, which then masqueraded as the user-configured base
      // duration on the next Start press (typically sub-5-minute
      // distraction remainders). Clear values with non-zero seconds
      // (users pick whole minutes) and any value ≤ 5 minutes (the
      // distraction default and Add/Remove time floor).
      await m.database.customStatement(
        "UPDATE priority_blocks "
        "SET duration = NULL, updated_at = datetime('now') "
        "WHERE duration IS NOT NULL "
        "  AND (duration % 60 <> 0 OR duration <= 300)",
      );
    }
    if (from < 331) {
      // Schema bump exists only to trigger _createPerfIndexes below,
      // which now includes partial indices on `pending IS NOT NULL` for
      // every pushed table. The push claim query
      // (`UPDATE … pending IS NOT NULL RETURNING *`) was full-scanning
      // these tables on every push attempt — measured 800–1100ms on
      // links and thread_tags during syncAll. No data migration here.
    }
    if (from < 332) {
      // Team membership sync. Creates the team_users table that mirrors the
      // server's user.team_user view. Used to track which teams the user
      // belongs to and detect team-leave transitions (archived_at transitions
      // NULL → non-NULL). Priority archival on team leave is handled server-side
      // (Task 6 trigger) and propagated to the client via the normal priority
      // sync cursor.
      try {
        await m.createTable(teamUsers);
      } catch (e) {
        // Tolerate "already exists" in case a previous build at 331 already
        // created this table (the team-firewall branch reserved 331 before
        // it was reassigned to the perf-index bump on main).
        if (!e.toString().toLowerCase().contains('already exists')) rethrow;
      }
    }
    if (from < 333) {
      // Historic add for the per-user rule anchor (then called
      // "auto_archived_by_thread_id"; later renamed to "mute_by_thread_id"
      // at v344 to match server-side rename). Add via raw SQL with the
      // original column name so the v333 → v344 sequence renames it
      // consistently across all upgrade paths.
      try {
        await m.database.customStatement(
          'ALTER TABLE threads ADD COLUMN auto_archived_by_thread_id BLOB',
        );
      } catch (e) {
        if (!e.toString().contains('duplicate column')) rethrow;
      }
    }
    if (from < 334) {
      // Access-loss tombstone column: when the server emits a row from
      // user.thread_redacted (user removed from group / team), it lands
      // with revoked=true and the sync layer hard-deletes the local row.
      // Default false for existing rows.
      await _safeAddColumn(m, threads, threads.revoked);
    }
    if (from < 335) {
      // Legacy `action` column on schedules — dropped at v336 when per-user
      // state moved off `schedule` onto `thread_state` (and then onto the
      // thread row as `action_type`). Added as a no-op so older schemas
      // catch up to the (then-current) v335 shape.
      await _safeCustomStatement(
        m,
        'ALTER TABLE schedules ADD COLUMN action TEXT',
      );
      // Reset schedule sync cursor so existing schedules re-pull with the
      // new shape on the next sync.
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'schedules'",
      );
    }
    if (from < 336) {
      // Server retired `urgency` on thread_unread (renamed thread_state) and
      // absorbed per-user schedule fields (action / order / on / at) onto the
      // per-user row. Add the new Thread columns; drop the legacy ones on
      // Thread + Schedule by rebuilding the tables from the current schema.
      // NOTE: `action_type` text column was added here in v336 and then
      // dropped in v339 in favor of three independent booleans. Use a raw
      // ALTER for the legacy column since Drift no longer knows about it.
      await _safeCustomStatement(
        m,
        'ALTER TABLE threads ADD COLUMN action_type TEXT',
      );
      await _safeAddColumn(m, threads, threads.urgent);
      await _safeAddColumn(m, threads, threads.stateOrder);
      await _safeAddColumn(m, threads, threads.stateOn);
      await _safeAddColumn(m, threads, threads.stateAt);
      // Drop `urgency` from threads, and `user_id`/`order`/`action`/
      // `outstanding_tasks` from schedules. TableMigration with no
      // columnTransformer rebuilds each table keeping only the columns
      // currently declared in Dart, which is exactly what we want.
      await m.alterTable(TableMigration(threads));
      await m.alterTable(TableMigration(schedules));
      // Reset cursors so the freshly-shaped rows re-pull with the new fields.
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity IN ('threads', 'schedules')",
      );
    }
    if (from < 337) {
      // Server collapsed see_within_requests / see_within_updates into a
      // single see_within column. Add the new columns, copy the requests
      // value over (matches the server's chosen carry-over), then rebuild
      // the priorities table to drop the legacy columns.
      await _safeAddColumn(m, priorities, priorities.seeWithin);
      await _safeAddColumn(m, priorities, priorities.seeWithinSet);
      await _safeCustomStatement(
        m,
        'UPDATE priorities SET see_within = see_within_requests '
        'WHERE see_within IS NULL AND see_within_requests IS NOT NULL',
      );
      await _safeCustomStatement(
        m,
        'UPDATE priorities SET see_within_set = see_within_requests_set '
        'WHERE see_within_set = 0 AND see_within_requests_set = 1',
      );
      await m.alterTable(TableMigration(priorities));
      // Reset priorities cursor so updated rows re-pull with the new shape.
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'priorities'",
      );
    }
    if (from < 338) {
      // Response-times rework: added two mechanisms (schedule respond +
      // early notifications), each with toggle/windows/SLA. The respond
      // half was removed at v347, so its raw-SQL ALTERs land here and
      // disappear during v347's TableMigration rebuild. The early-
      // notifications half still lives on the table.
      await _safeCustomStatement(m,
        'ALTER TABLE priorities ADD COLUMN respond_schedule_enabled INTEGER');
      await _safeCustomStatement(m,
        'ALTER TABLE priorities ADD COLUMN respond_window TEXT');
      await _safeCustomStatement(m,
        'ALTER TABLE priorities ADD COLUMN respond_within TEXT');
      await _safeAddColumn(m, priorities, priorities.earlyNotificationsEnabled);
      await _safeAddColumn(m, priorities, priorities.notifyWindow);
      await _safeCustomStatement(m,
        'ALTER TABLE priorities ADD COLUMN respond_schedule_enabled_set INTEGER NOT NULL DEFAULT 0');
      await _safeCustomStatement(m,
        'ALTER TABLE priorities ADD COLUMN respond_window_set INTEGER NOT NULL DEFAULT 0');
      await _safeCustomStatement(m,
        'ALTER TABLE priorities ADD COLUMN respond_within_set INTEGER NOT NULL DEFAULT 0');
      await _safeAddColumn(
        m,
        priorities,
        priorities.earlyNotificationsEnabledSet,
      );
      await _safeAddColumn(m, priorities, priorities.notifyWindowSet);
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'priorities'",
      );
    }
    if (from < 339) {
      // Unify the feed: replace `action_type` with the `active` boolean.
      // Backfill from the existing string column before dropping it, then
      // reset the threads cursor so the next sync pulls the new server-side
      // columns. (This step originally also added `task`/`to_read` booleans
      // for the task-list / reading-list features; those were removed in
      // v349, and the TableMigration below already rebuilds to the current
      // schema, so they're no longer added here.)
      await _safeAddColumn(m, threads, threads.active);
      await _safeCustomStatement(
        m,
        "UPDATE threads SET active = 1 "
        "WHERE action_type IN ('respond', 'do')",
      );
      await m.alterTable(TableMigration(threads));
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'threads'",
      );

      // Add external_accounts column to actors. The server's user.actor
      // view aggregates contact_external_account rows as a JSON array so
      // the DM picker can filter contacts by reachable messaging platform
      // without a network call. Resetting the actors cursor re-pulls every
      // row with the new column populated.
      await _safeAddColumn(m, actors, actors.externalAccounts);
      await m.database.customStatement(
        "UPDATE sync_states SET last_horizon = 0, pulled_at = 0 WHERE entity LIKE 'user_actors%'",
      );
    }
    if (from < 340) {
      // external_accounts JSON shape changed: each entry now keys on
      // `twist_instance_id` instead of just `provider`, so a Plot contact
      // reachable through multiple connections (two Slack workspaces,
      // Gmail + Google Chat sharing one Google account) has one entry per
      // connection. Existing local JSON is for the old shape — drop it and
      // re-pull from the server so every row arrives in the new shape.
      await m.database.customStatement(
        "UPDATE actors SET external_accounts = '[]'",
      );
      await m.database.customStatement(
        "UPDATE sync_states SET last_horizon = 0, pulled_at = 0 WHERE entity LIKE 'user_actors%'",
      );
    }
    if (from < 341) {
      // Per-contact role metadata on threads (To/CC/BCC, Required/Optional).
      // Existing rows will pick up the column as null and treat every contact
      // as the link type's default role.
      await m.addColumn(threads, threads.contactMeta);
    }
    if (from < 342) {
      // Emoji reactions: parallel to note_tags / thread_tags but keyed by
      // emoji string (Unicode grapheme cluster or `<provider>:<ws>/<name>`
      // custom-emoji ref). Adds three tables; sync state for the new
      // endpoints will be initialized lazily on first pull. Strictly
      // additive — count tags on existing rows keep working until Phase 6.
      await m.createTable(noteReactions);
      await m.createTable(threadReactions);
      await m.createTable(customEmojis);
    }
    if (from < 343) {
      // Toggle-tag retirement (mirrors server migration
      // 20260527023511_drop_toggle_tags). Strip the 10 retired tag ids
      // (100, 101, 103-108, 110, 111) from each row's tags JSON, and
      // rename Tag.twist's id from 109 to 12 (compute range).
      //
      // The local schema stores tags as a single JSON blob keyed by tag id
      // (e.g. `{"1":["actorA"], "110":["actorB"]}`), not row-per-(note, tag,
      // actor) like the server. So we patch the JSON instead of updating
      // `tag_id` / `archived_at` columns — those don't exist locally.
      const stripRetired = '{"100":null,"101":null,"103":null,"104":null,'
          '"105":null,"106":null,"107":null,"108":null,"110":null,"111":null}';
      for (final tbl in const ['note_tags', 'thread_tags']) {
        // Remove retired keys from `tags` (RFC 7396 merge patch: null keys
        // are deleted).
        await m.database.customStatement(
          "UPDATE $tbl SET tags = json_patch(tags, '$stripRetired') "
          'WHERE tags IS NOT NULL',
        );
        // Rename "109" → "12" by re-keying the existing value.
        await m.database.customStatement(
          'UPDATE $tbl '
          r'''SET tags = json_set(json_remove(tags, '$."109"'), '''
          r''''$."12"', json_extract(tags, '$."109"')) '''
          'WHERE tags IS NOT NULL '
          r'''AND json_extract(tags, '$."109"') IS NOT NULL''',
        );
        // Collapse an emptied object back to NULL so the UI doesn't try to
        // render a blank chip row before the next sync arrives.
        await m.database.customStatement(
          "UPDATE $tbl SET tags = NULL WHERE tags = '{}'",
        );
      }
    }
    if (from < 344) {
      // Rename `auto_archived_by_thread_id` → `mute_by_thread_id` to match
      // the server-side rename (Skip active for threads like this). Wrapped
      // in a try/catch because SQLite reports the rename as a no-op when
      // the source column has already been removed by a previous partial
      // upgrade.
      try {
        await m.database.customStatement(
          'ALTER TABLE threads '
          'RENAME COLUMN auto_archived_by_thread_id TO mute_by_thread_id',
        );
      } catch (e) {
        final msg = e.toString().toLowerCase();
        // Already renamed or column doesn't exist on this client → no-op.
        if (!msg.contains('no such column') &&
            !msg.contains('duplicate column')) {
          rethrow;
        }
      }
    }
    if (from < 345) {
      await m.addColumn(twistInstances, twistInstances.handle);
      await m.addColumn(twistInstances, twistInstances.threadType);
    }
    if (from < 346) {
      await m.addColumn(threads, threads.droppedContacts);
    }
    if (from < 347) {
      // Drop the "Schedule time to respond" columns from the priorities
      // table. The feature was removed in favour of explicit focus
      // blocks; only the early-notifications half remains. TableMigration
      // rebuilds the table keeping only the columns Drift still knows
      // about, so the respond_* columns disappear.
      //
      // `icon` is declared as a new column: it was added to the Dart schema
      // after this step shipped, so it doesn't exist in pre-347 databases.
      // Without this, the rebuild's INSERT...SELECT would copy a nonexistent
      // `icon` and throw, forcing a full reset. Listing it here excludes it
      // from the copy (it gets its NULL default instead). The same applies to
      // every priority column added to the Dart schema after this step:
      // `role_id` / `is_inbox` (v368, focus roles) and `notification_cleared_at`
      // (v366) likewise don't exist in a pre-347 table, so they must be listed
      // as new columns here too or the rebuild copies a nonexistent column and
      // forces a full reset.
      await m.alterTable(
        TableMigration(
          priorities,
          newColumns: [
            priorities.icon,
            priorities.notificationClearedAt,
            priorities.roleId,
            priorities.isInbox,
            priorities.isFyi,
          ],
        ),
      );
      await m.database.customStatement(
        "UPDATE sync_states SET pulled_at = 0 WHERE entity = 'priorities'",
      );
    }
    if (from < 348) {
      // The focus icon column was added to the priorities schema (focus A7.1)
      // without a migration or version bump, so databases already at 347 never
      // gained the column and priority queries crashed with
      // "no such column: base.icon". Add it for them. `_safeAddColumn` ignores
      // the duplicate-column error from clients that upgraded through the
      // amended `from < 347` rebuild above, which already creates the column.
      await _safeAddColumn(m, priorities, priorities.icon);
    }
    if (from < 349) {
      // Drop the `task` and `to_read` columns from the threads table — the
      // task-list and reading-list features were removed. TableMigration
      // rebuilds the table keeping only the columns Drift still knows about,
      // so the dropped columns disappear.
      await m.alterTable(TableMigration(threads));
    }

    if (from < 350) {
      // Use _safeAddColumn so test harnesses that open the store at the
      // current schema and roll back user_version don't trip a duplicate-
      // column error (same rationale as the `_safeAddColumn` call above for
      // priorities.icon).
      await _safeAddColumn(m, notes, notes.accessGroups);
    }

    if (from < 351) {
      // Flat priority model: drop the obsolete `priority_children` view that
      // expanded a priority to its self+descendants via path LIKE. The view
      // has no remaining consumers; views are recreated at the end of
      // onUpgrade, but only those still declared in the Drift schema.
      await m.database.customStatement('DROP VIEW IF EXISTS priority_children');
    }

    if (from < 352) {
      // Link access-loss tombstone column (user.link_redacted).
      await _safeAddColumn(m, links, links.revoked);
      // One-time cleanup: enforce "a connector link whose owning
      // twist_instance is archived must not exist locally" — clears orphan
      // links (and their schedules) stranded by the old server hard-delete
      // that didn't sync. Exact and safe: user-authored links have a user-id
      // created_by (no matching twist_instance); reconnect-revived links point
      // at a live instance.
      await _safeCustomStatement(m, '''
        DELETE FROM schedules WHERE link_id IN (
          SELECT l.id FROM links l
          JOIN twist_instances ti ON ti.id = l.created_by
          WHERE ti.archived_at IS NOT NULL
        )
      ''');
      await _safeCustomStatement(m, '''
        DELETE FROM links WHERE created_by IN (
          SELECT id FROM twist_instances WHERE archived_at IS NOT NULL
        )
      ''');
    }

    if (from < 353) {
      // Two-step thread creation: threads carry a nullable team scope
      // (`thread.team_id` on the server). Null = Personal. Round-trips
      // through sync; set at draft creation time only.
      await m.addColumn(threads, threads.teamId);
    }

    if (from < 354) {
      // Focuses are team-agnostic: drop priorities.team_id and the per-focus
      // default sharing columns (default_contacts/default_groups/
      // default_invite_emails). Team scope now lives on thread.team_id and the
      // two-step target picker drives a thread's roster. TableMigration
      // rebuilds the table keeping only the columns Drift still declares, so
      // the dropped columns disappear.
      await m.alterTable(TableMigration(priorities));
    }

    if (from < 355) {
      // Sync the group `key` (e.g. `@plot.team`) so Help & Feedback can resolve
      // the Plot Team group offline. _safeAddColumn keeps it idempotent for
      // test harnesses opened at the current schema.
      await _safeAddColumn(m, groups, groups.key);
    }

    if (from < 356) {
      // Sync thread.author_id (the actor credited with causing the thread's
      // creation). Mirrors link.author_id; not yet surfaced in the UI.
      await m.addColumn(threads, threads.authorId);
    }

    if (from < 357) {
      await _safeAddColumn(m, threads, threads.assigneeId);
    }

    if (from < 358) {
      await m.createTable(topics);
      await m.addColumn(groups, groups.privacy);
      await m.addColumn(groups, groups.canAddress);
      await m.addColumn(threads, threads.topicId);
    }

    if (from < 359) {
      // Local-only intent flag; never synced. See Groups.membersDirty.
      await m.addColumn(groups, groups.membersDirty);
    }

    if (from < 360) {
      // Sync twist.reaction_capabilities (what reactions a connector's
      // source platform supports). Drives the data-driven reaction picker.
      await _safeAddColumn(
        m,
        twistInstances,
        twistInstances.reactionCapabilities,
      );
    }

    if (from < 361) {
      // Sync twist_instance.custom_emoji_scope: an opaque per-connection
      // token (e.g. `slack:T0123ABC`) used to offer "this connection's custom
      // emoji" in the reaction picker (prefix-match against custom_emoji.id).
      await _safeAddColumn(
        m,
        twistInstances,
        twistInstances.customEmojiScope,
      );
    }
    if (from < 362) {
      await _safeAddColumn(m, links, links.priority);
      await _safeAddColumn(m, links, links.noteScoped);
    }
    if (from < 363) {
      // Classifier description stored on the focus so it flows to the
      // /sync/priorities upsert payload. Nullable; existing rows get NULL.
      await _safeAddColumn(m, priorities, priorities.description);
    }
    if (from < 364) {
      // Recover threads stranded by the published-note-on-draft-thread bug.
      // A published note (draft=0) whose parent thread is still a local
      // draft (draft=1) can never sync: the draft thread is excluded from
      // push, so it has no server-side thread_priority and POST /sync/notes
      // 403s forever. The push filter (Store._buildDraftFilter) now blocks
      // such a note, which stops the loop but leaves its content stranded
      // locally with `pending` set. Honor the user's publish intent: promote
      // the parent thread to draft=0 so it — and the note — sync normally
      // (the server's upsert_thread self-files thread_priority for a new
      // user-created thread). Guarded to valid, non-archived threads that
      // have a focus filing so we never push an invalid thread.
      await m.database.customStatement('''
        UPDATE threads
        SET draft = 0, pending = 2
        WHERE draft = 1
          AND archived_at IS NULL
          AND priority_id IS NOT NULL
          AND id IN (
            SELECT thread_id FROM notes
            WHERE draft = 0 AND archived_at IS NULL AND thread_id IS NOT NULL
          )
      ''');
      // Any note still sitting on a thread we could not promote (archived or
      // missing a focus filing) is demoted back to draft so it stops being a
      // stranded inconsistency and is correctly excluded from push. No
      // content is deleted — the note stays editable locally.
      await m.database.customStatement('''
        UPDATE notes
        SET draft = 1
        WHERE draft = 0
          AND archived_at IS NULL
          AND thread_id IN (SELECT id FROM threads WHERE draft = 1)
      ''');
    }
    if (from < 365) {
      // Cross-device record of which focus suggestions the user has created a
      // focus from. Nullable; existing rows get NULL (= none dismissed).
      await _safeAddColumn(
        m,
        userSettings,
        userSettings.dismissedFocusSuggestions,
      );
    }

    if (from < 366) {
      await _safeAddColumn(m, priorities, priorities.notificationClearedAt);
    }

    if (from < 367) {
      // Backfill idx_threads_draft. The chain-draft lookup and the
      // duplicate-draft cleanup that run on every focus switch were
      // full-scanning the threads table for `draft = 1 AND archived_at IS
      // NULL` (no index supported that predicate) — ~200ms–1s per scan,
      // twice per switch, on populated workspaces. No data migration.
      await _createPerfIndexes(m.database);
    }

    if (from < 368) {
      // Focus roles: the new `roles` table (synced from /sync/roles) plus
      // `priority.role_id` / `priority.is_inbox`. Purely additive — the server
      // backfills role_id/is_inbox on the next sync; no local data migration.
      await m.createTable(roles);
      await _safeAddColumn(m, priorities, priorities.roleId);
      await _safeAddColumn(m, priorities, priorities.isInbox);
    }

    if (from < 369) {
      // Client path-independence: `priorities.path` is now nullable so a future
      // API that stops sending `path` to apiVersion >= 5 clients can't crash
      // row deserialization. TableMigration rebuilds the table from the current
      // Drift schema (path now NULLABLE), preserving existing path data.
      await m.alterTable(TableMigration(priorities));

      // Focus-scoped sync cursor anchors moved from path-keyed
      // (`activity-feed:<path>` / `agenda:<path>`) to id-keyed
      // (`activity-feed:<uuid>` / `agenda:<uuid>`). Existing path-keyed rows
      // would never match again — drop them so the one-time re-pull is clean
      // (the new id-keyed states are created on demand on next sync).
      await m.database.customStatement(
        "DELETE FROM sync_states WHERE entity LIKE 'activity-feed:%' OR entity LIKE 'agenda:%'",
      );
    }

    if (from < 370) {
      await m.addColumn(notes, notes.cta);
    }

    if (from < 371) {
      await _safeAddColumn(m, priorities, priorities.isFyi);
    }

    if (from < 372) {
      // Client-only durability marker for the /sync/thread-state push.
      // Default false: anything truly unpushed pre-upgrade was already lost
      // by the old fire-and-forget push, so existing rows start clean.
      await _safeAddColumn(m, threads, threads.statePending);
    }

    if (from < 373) {
      // Drop the vestigial `priorities.root` flag. In the flat/role model
      // nothing reads it — the default Inbox is resolved from `is_inbox` +
      // role age — so it carried no meaning. The server may still send `root`
      // for now; `PrioritiesBase.fromBase` strips it before deserialization.
      // TableMigration rebuilds the table from the current Drift schema (no
      // `root` column), preserving all other data.
      await m.alterTable(TableMigration(priorities));
    }

    if (from < 374) {
      // Runtime-only "Failed to send" marker. NULL everywhere on upgrade; only
      // the server ever sets it (synced in like cta).
      await _safeAddColumn(m, notes, notes.deliveryError);
    }

    if (from < 375) {
      // Cross-device per-source-focus move affinity (Move modal recency tier).
      // Non-null TEXT with a '{}' default; existing rows get the empty map.
      await _safeAddColumn(m, userSettings, userSettings.moveAffinity);
    }

    if (from < 376) {
      // One-time cleanup for the access-loss strand fixed in
      // `Thread._hardDeleteRevokedThreads`: revoking a thread used to
      // hard-delete its notes but leave the `note_tags` rows (keyed by note
      // id) behind. An orphaned note_tags row keeps its `pending` bit, so the
      // sync loop re-pushed it to /sync/note-tags/update forever — the server
      // rejected every push with 422 "User does not have access to this
      // priority" (the thread_priority row is revoked) and the client reported
      // it to error tracking on each retry. Purge note_tags rows whose note no
      // longer exists locally and that still carry a pending push: the tag
      // update targets a note the user can't reach, so it can never succeed.
      await _safeCustomStatement(m, '''
        DELETE FROM note_tags
        WHERE pending IS NOT NULL
          AND id NOT IN (SELECT id FROM notes)
      ''');
    }

    if (from < 377) {
      // Scheduled sending: send_at on notes (the hold instant) and threads
      // (mirrored hold for a scheduled new-thread compose); send_window on
      // focuses and roles (auto-schedule outside the window).
      await _safeAddColumn(m, notes, notes.sendAt);
      await _safeAddColumn(m, threads, threads.sendAt);
      await _safeAddColumn(m, priorities, priorities.sendWindow);
      await _safeAddColumn(m, priorities, priorities.sendWindowSet);
      await _safeAddColumn(m, roles, roles.sendWindow);
    }

    if (from < 378) {
      // Forward a note: fwd_note points at the note being forwarded, mirroring
      // re_note (reply-to). Nullable — no data migration needed.
      await _safeAddColumn(m, notes, notes.fwdNoteId);
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
    // idx_schedules_user_id retired: per-user schedule rows no longer exist.
    await db.customStatement('DROP INDEX IF EXISTS idx_schedules_user_id');
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_links_thread_id '
      'ON links(thread_id) WHERE thread_id IS NOT NULL',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_threads_priority_id '
      'ON threads(priority_id)',
    );
    // Draft lookup on focus switch. `getDraftInChain` (find the chain draft)
    // and the per-switch duplicate-draft cleanup both query
    // `WHERE draft = 1 AND archived_at IS NULL` (the cleanup also adds
    // `priority_id = ?`). Nothing indexed that predicate, so each switch
    // full-scanned the threads table — measured 200ms–1s per scan on a
    // populated workspace, and it runs twice per switch.
    //
    // `draft` is the LEADING indexed column (not the partial predicate):
    // Drift emits `draft = ?` as a bound parameter, and SQLite cannot prove a
    // parameter equals the constant in a partial-index predicate, so it would
    // refuse a `WHERE draft = 1` partial index. Equality on an indexed
    // *column* binds fine, so a leading `draft` column lets the planner seek
    // straight to the tiny `draft = 1` slice (even when there's no
    // `priority_id` filter, as in getDraftInChain). `archived_at IS NULL` is
    // the partial predicate because that term IS non-parameterized and keeps
    // the index small. `priority_id` second covers the cleanup's
    // `priority_id = ?`. The trailing ANALYZE teaches the planner to prefer it
    // (same reasoning as the partial `pending` indices below).
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_threads_draft '
      'ON threads(draft, priority_id) WHERE archived_at IS NULL',
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

    // Partial indices on `pending` for every pushed table. The push
    // claim query is a `UPDATE … SET pending = pending | 1 WHERE
    // pending IS NOT NULL … RETURNING *` issued once per entity per
    // syncAll. Most rows have `pending = NULL` (never edited locally,
    // or already cleared on push success), so a tiny partial index
    // (only non-null rows are present) lets SQLite skip the table scan
    // entirely. Measured ~800–1100ms claim times on links and
    // thread_tags on populated workspaces — partial indices drop that
    // to single-digit ms when nothing is pending.
    const pushedTables = [
      'priorities',
      'twist_instances',
      'threads',
      'schedules',
      'links',
      'thread_tags',
      'thread_associations',
      'sessions',
      'notes',
      'note_tags',
      'priority_blocks',
    ];
    for (final t in pushedTables) {
      await db.customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${t}_pending '
        'ON $t(pending) WHERE pending IS NOT NULL',
      );
    }

    // Refresh statistics so the SQLite query planner picks the new
    // partial indices for the push claim query. Without ANALYZE, the
    // planner falls back to row-count heuristics and was observed to
    // skip the partial index on populated tables (links, notes still
    // ~1s claims after adding the index) — ANALYZE drops those to a
    // few ms because the partial index is tiny.
    await db.customStatement('ANALYZE');
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
    if (state != AppLifecycleState.resumed) return;
    if (store._isSyncing) return;

    // Always pull on resume. Even when the WebSocket appears connected, we may
    // have missed broadcasts while backgrounded (dropped frames, transient
    // server-side gaps, zombie sockets). If the socket is dead, _startSync
    // re-subscribes; otherwise _syncAll just catches up via the seq cursor.
    if (store._broadcastClient?.isConnected == true) {
      if (syncPerfLog) {
        _log.info('App resumed — pulling for catch-up');
      }
      store._syncAll(trigger: 'resume').catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _log.warning('Resume-triggered pull failed', error, stackTrace);
        return null;
      });
    } else {
      _log.info('App resumed, WebSocket disconnected — triggering full sync');
      store._startSync(trigger: 'resume').catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _log.warning('Resume-triggered sync failed', error, stackTrace);
        return null;
      });
    }
  }
}
