part of 'store.dart';

final _syncOrchestratorLog = Logger('plot.sync_orchestrator');

/// Orchestrates sync operations across all entities with dependency awareness.
///
/// Provides:
/// - Type-safe entity references (SyncOrchestrator.thread, etc.)
/// - Automatic dependency ordering via topological sort
/// - Parallel execution of independent entities
/// - Push and pull with dependency validation
class SyncOrchestrator {
  static SyncOrchestrator? _instance;
  static SyncOrchestrator get instance => _instance ??= SyncOrchestrator._();

  SyncOrchestrator._();

  // Track in-flight operations to prevent concurrent sync of same entity
  final Map<SyncEntity, Completer<bool>> _pushCompleters = {};
  final Map<SyncEntity, Completer<void>> _pullCompleters = {};

  // True while [syncAll] is running. Keeps completed [_pushCompleters]
  // entries in the map across push levels so the recursive dep-walk
  // inside each entity's push doesn't re-push every parent in every
  // level — without this flag, the per-call `finally` clears the
  // completer between levels and `push(priority)` runs once per
  // descendant level. Cleared by syncAll's own finally.
  bool _syncAllInProgress = false;

  // Entities marked dirty during an in-flight pull. After the in-flight pull
  // completes, each dirty entity is pulled again so updates that arrived
  // mid-pull aren't deferred until the next broadcast cycle.
  final Set<SyncEntity> _pullDirty = {};

  // 429 rate-limit cooldown tracking
  DateTime? _lastRateLimitAt;
  Duration _rateLimitCooldown = const Duration(seconds: 5);

  // ============================================================================
  // STATIC ENTITY DEFINITIONS (type-safe!)
  // ============================================================================

  /// Actor entity. Contacts are writable (add/rename); other actor types are
  /// read-only and never get a pending flag, so push is a no-op for them.
  static final actor = SyncEntity(
    debugName: 'actor',
    dependsOn: [],
    pushFn: Actor.push,
    pullFn: Actor.pull,
  );

  /// Group entity (read-only, no dependencies)
  /// Group entity (writable: create / rename / membership).
  static final group = SyncEntity(
    debugName: 'group',
    dependsOn: [actor],
    pushFn: Group.push,
    pullFn: Group.pull,
  );

  /// Topic entity (read-only, no dependencies). The client is on apiVersion 4,
  /// so /sync/topics returns the new topic entity (user.topic), not the legacy
  /// group-compat shape.
  static final topic = SyncEntity(
    debugName: 'topic',
    dependsOn: [],
    pushFn: () async => true, // Read-only, skip push
    pullFn: Topic.pull,
  );

  /// TeamUser entity (read-only, no dependencies).
  /// Tracks which teams the current user belongs to. On a team-leave the
  /// server archives the user's team priorities (Task 6 trigger); those
  /// changes arrive via the normal priority sync cursor. No explicit
  /// client-side cascade is needed beyond applying the team_user update.
  static final teamUser = SyncEntity(
    debugName: 'team_user',
    dependsOn: [],
    pushFn: () async => true, // Read-only, skip push
    pullFn: TeamUser.pull,
  );

  /// UserSettings entity (no dependencies, per-user settings)
  static final userSettings = SyncEntity(
    debugName: 'user_settings',
    dependsOn: [],
    pushFn: UserSettingsEntity.push,
    pullFn: UserSettingsEntity.pull,
  );

  /// Priority entity (depends on actor for createdBy)
  static final priority = SyncEntity(
    debugName: 'priority',
    dependsOn: [actor],
    pushFn: Priority.push,
    pullFn: Priority.pull,
  );

  /// TwistInstance entity (depends on priority)
  static final twistInstance = SyncEntity(
    debugName: 'twist_instance',
    dependsOn: [priority],
    pushFn: TwistInstance.push,
    pullFn: () async {
      await TwistInstance.pullInitial();
      await TwistInstance.pullUpdates();
    },
  );

  /// Source channel entity (depends on twist_instance)
  static final channel = SyncEntity(
    debugName: 'channel',
    dependsOn: [twistInstance],
    pushFn: () async => true, // Read-only — no-op push always succeeds
    pullFn: Channel.pull,
  );

  /// Per-(twist_instance, provider, actor) connection status (read-only).
  /// Surfaces needs_reauth and initial_syncing signals from
  /// user.twist_connection. Bumped server-side by the user_sync trigger on
  /// twist_instance_connection.
  static final twistConnection = SyncEntity(
    debugName: 'twist_connection',
    dependsOn: [twistInstance],
    pushFn: () async => true, // Read-only — re-auth happens via OAuth flow
    pullFn: TwistConnection.pull,
  );

  /// Thread entity (depends on priority and actor)
  /// Note: Thread.push() and Thread.pull() also handle Schedules, Links, and ThreadTags
  static final thread = SyncEntity(
    debugName: 'thread',
    dependsOn: [priority, actor],
    pushFn: Thread.push,
    pullFn: () async {
      await Thread.pullInitial();
      await Thread.pull();
    },
  );

  /// PriorityBlock entity (depends on priority and actor)
  static final priorityBlock = SyncEntity(
    debugName: 'priority_block',
    dependsOn: [priority, actor],
    pushFn: PriorityBlock.push,
    pullFn: PriorityBlock.pull,
  );

  /// Session entity (depends on priority)
  static final session = SyncEntity(
    debugName: 'session',
    dependsOn: [priority],
    pushFn: Session.push,
    pullFn: Session.pull,
  );

  /// Note entity (depends on thread and actor)
  /// Note: Note.push(), Note.pullInitial(), and Note.pullUpdates() also handle NoteTags
  static final note = SyncEntity(
    debugName: 'note',
    dependsOn: [thread, actor],
    pushFn: Note.push,
    pullFn: () async {
      await Note.pullUpdates();
    },
  );

  /// All syncable entities in dependency order (for iteration)
  static final allEntities = [
    actor,
    group,
    topic,
    teamUser,
    userSettings,
    priority,
    priorityBlock,
    twistInstance,
    channel,
    twistConnection,
    thread,
    session,
    note,
  ];

  // ============================================================================
  // INITIAL SYNC ENTITY DEFINITIONS
  // ============================================================================

  /// Thread entity for critical initial sync — only pulls agenda + activity feed.
  /// Skips unread threads, schedules initial, and incremental pull.
  ///
  /// Deliberately does NOT do a full `links` pull here. `pullAgenda` /
  /// `pullActivityFeed` each fetch the links for the threads they slice in
  /// via bounded `pullTo` calls (thread.dart:812-834, 862-883), which is all
  /// the UI needs to render. The full account-wide link pull happens later
  /// in `syncInitialDeferred` via `Thread.pullInitial()` / `Thread.pull()`.
  /// Doing it eagerly here used to dominate the 30s critical-sync budget
  /// for accounts with large link histories.
  static final _threadCritical = SyncEntity(
    debugName: 'thread_critical',
    dependsOn: [priority, actor],
    pushFn: () async => true,
    pullFn: () async {
      await Future.wait([
        Thread.pullAgenda(null, null),
        Thread.pullActivityFeed(null, null),
      ]);
    },
  );

  /// TwistInstance for critical initial sync — initial only, no updates.
  /// Uses `pullInitial` (single bounded page) rather than `pull` (initial +
  /// full incremental sweep) so the critical path stays inside its 30s
  /// budget. Incremental updates are handled later by the regular
  /// `twistInstance` entity in `syncInitialDeferred`.
  static final _twistInstanceCritical = SyncEntity(
    debugName: 'twist_instance_critical',
    dependsOn: [priority],
    pushFn: () async => true,
    pullFn: TwistInstance.pullInitial,
  );

  /// Entities needed for the critical initial sync (minimum to render UI).
  ///
  /// INVARIANT — keep this list tight. A common user flow is "sign in on a
  /// fresh browser / new device with a long-lived account," which means
  /// EVERY entity here pulls from `seq=0` against potentially huge tables.
  /// `syncInitialCritical` runs under a 30s wall-clock budget (see
  /// `Store._startSyncCritical` and the 30s timeout in `Store.start`); if
  /// it exceeds that, the user sits on a loading screen and (until the
  /// timeout was made non-fatal) used to get signed out.
  ///
  /// Before adding an entity here, ask:
  ///   1. Is it required for the very first paint? If not, put it in
  ///      `syncInitialDeferred` instead.
  ///   2. Is the pull bounded (a single page / a `pullTo` slice) or does
  ///      it paginate through the entire table? Critical entities must be
  ///      bounded — see `_threadCritical` and `_twistInstanceCritical`
  ///      for the pattern.
  ///   3. Does its `pullFn` call any helper that itself does an unbounded
  ///      `Store.pull(...)` on a high-volume table (e.g. links, threads,
  ///      schedules, notes)? If yes, that helper is the wrong primitive
  ///      for this list.
  static final _criticalEntities = [
    actor,
    userSettings,
    priority,
    priorityBlock,
    _threadCritical,
    _twistInstanceCritical,
  ];

  // ============================================================================
  // PUBLIC API
  // ============================================================================

  /// Maps table names to [SyncEntity] instances.
  ///
  /// Accepts both Drift table names (e.g. 'user_thread') from local saves
  /// and broadcast entity names (e.g. 'thread') from server sync notifications.
  /// Returns null for unknown table names.
  static SyncEntity? getEntityByTableName(String table) {
    return switch (table) {
      'user_actor' || 'actor' => actor,
      'user_group' || 'group' => group,
      'user_topic' || 'topic' => topic,
      'user_team_user' || 'team_user' => teamUser,
      'user_settings' => userSettings,
      'user_priority' || 'priority' => priority,
      'user_priority_block' || 'priority_block' || 'priority_blocks' => priorityBlock,
      'user_twist' || 'twist_instance' => twistInstance,
      'user_channel' || 'channel' => channel,
      'user_twist_connection' || 'twist_connection' => twistConnection,
      'user_thread' || 'user_link' || 'user_schedule' || 'user_thread_tags' ||
      'user_thread_reactions' ||
      'thread' || 'thread_read' || 'schedule' =>
        thread,
      'session' => session,
      'user_note' || 'user_note_tags' || 'user_note_reactions' || 'note' =>
        note,
      _ => null,
    };
  }

  /// Syncs all entities: pull all (parents→children), then push all (children→parents)
  ///
  /// This replaces the old _syncAll() method with a dependency-aware version.
  Future<void> syncAll() async {
    // Wait out 429 cooldown if active
    await _waitForRateLimitCooldown();

    final sw = Stopwatch()..start();
    if (syncPerfLog) {
      _syncOrchestratorLog.info('syncAll: start (pull → push)');
    }

    // Mark the syncAll window so push() preserves completers across
    // levels (see field doc). Clear any stale state from a previously
    // aborted run, then ensure the cleanup runs even if a phase throws.
    _syncAllInProgress = true;
    _pushCompleters.clear();

    try {
      // Phase 1: Pull all (parents → children)
      final pullLevels = _computePullLevels();
      for (var i = 0; i < pullLevels.length; i++) {
        final level = pullLevels[i];
        final levelSw = Stopwatch()..start();
        await _executePullLevel(level);
        if (syncPerfLog) {
          _syncOrchestratorLog.info(
            'syncAll: pull L$i (${level.length}) ${levelSw.elapsedMilliseconds}ms '
            '[${level.map((e) => e.debugName).join(",")}] @ ${sw.elapsedMilliseconds}ms',
          );
        }
      }
      final pullTotalMs = sw.elapsedMilliseconds;

      // Phase 2: Push all (children → parents)
      final pushLevels = _computePushLevels();
      for (var i = 0; i < pushLevels.length; i++) {
        final level = pushLevels[i];
        final levelSw = Stopwatch()..start();
        await _executePushLevel(level);
        if (syncPerfLog) {
          _syncOrchestratorLog.info(
            'syncAll: push L$i (${level.length}) ${levelSw.elapsedMilliseconds}ms '
            '[${level.map((e) => e.debugName).join(",")}] @ ${sw.elapsedMilliseconds}ms',
          );
        }
      }

      if (syncPerfLog) {
        _syncOrchestratorLog.info(
          'syncAll: complete ${sw.elapsedMilliseconds}ms '
          '(pull ${pullTotalMs}ms, push ${sw.elapsedMilliseconds - pullTotalMs}ms)',
        );
      }
    } finally {
      _syncAllInProgress = false;
      _pushCompleters.clear();
    }
  }

  /// Performs minimal sync for first-time users (and any user signing in on
  /// a fresh client / new browser with an empty local DB).
  ///
  /// MUST complete inside ~30s for a real account, otherwise the user is
  /// stuck on the "Setting things up…" screen. The 30s deadline is enforced
  /// by `Store.start`'s new-user branch. The deadline is now non-fatal —
  /// we proceed with whatever data is in place and let `syncInitialDeferred`
  /// finish the rest — but the goal remains the same: have enough loaded
  /// for the first paint to feel instant.
  ///
  /// "Fresh client with an existing account" is the most adversarial case:
  /// every critical entity pulls from `seq=0` against a populated remote.
  /// See `_criticalEntities` for what's allowed in this phase and why.
  /// No push phase (new users have nothing to push).
  Future<void> syncInitialCritical() async {
    await _waitForRateLimitCooldown();
    _syncOrchestratorLog.info('Starting critical initial sync');

    final pullLevels = _topologicalSort(_criticalEntities, forward: true);
    _syncOrchestratorLog.fine(
      'Critical pull levels: ${pullLevels.map((l) => l.map((e) => e.debugName).toList()).toList()}',
    );

    for (var i = 0; i < pullLevels.length; i++) {
      final level = pullLevels[i];
      _syncOrchestratorLog.fine(
        'Critical pulling level $i: ${level.map((e) => e.debugName).toList()}',
      );
      await _executePullLevel(level);
    }

    _syncOrchestratorLog.info('Completed critical initial sync');
  }

  /// Completes remaining sync work after critical path.
  /// Runs in background while app is already interactive.
  Future<void> syncInitialDeferred() async {
    await _waitForRateLimitCooldown();
    _syncOrchestratorLog.info('Starting deferred initial sync');

    // Complete the full thread pull (unread threads, schedules, incremental)
    // pullInitial and pull use sync state to skip already-pulled data.
    await pull(thread);

    // Pull non-critical entities in parallel where possible
    await Future.wait([
      pull(session),
      pull(channel),
      pull(note),
    ], eagerError: false);

    // Complete twistInstance updates (initial was done in critical)
    await pull(twistInstance);
    // twistConnection depends on twistInstance — pull after it's settled.
    await pull(twistConnection);

    // Push phase - all entities
    final pushLevels = _computePushLevels();
    for (var i = 0; i < pushLevels.length; i++) {
      final level = pushLevels[i];
      await _executePushLevel(level);
    }

    _syncOrchestratorLog.info('Completed deferred initial sync');
  }

  /// Syncs a subset of entities with their transitive dependencies.
  ///
  /// Computes the full dependency closure, then executes push and pull
  /// in topological order with parallelism within each level.
  Future<void> syncSubset(Set<SyncEntity> entities) async {
    // Wait out 429 cooldown if active
    await _waitForRateLimitCooldown();

    // Compute transitive dependency closure
    final closure = <SyncEntity>{};
    void addWithDeps(SyncEntity entity) {
      if (closure.add(entity)) {
        for (final dep in entity.dependsOn) {
          addWithDeps(dep);
        }
      }
    }
    for (final entity in entities) {
      addWithDeps(entity);
    }

    final closureList = closure.toList();
    _syncOrchestratorLog.fine(
      'syncSubset: ${entities.map((e) => e.debugName)} '
      '→ closure: ${closureList.map((e) => e.debugName).toList()}',
    );

    // Push requested entities (not deps) in topological order
    final pushLevels = _topologicalSort(closureList, forward: true);
    for (final level in pushLevels) {
      // Only push entities that were explicitly requested (not just deps)
      final toPush = level.where((e) => entities.contains(e)).toList();
      if (toPush.isNotEmpty) {
        await _executePushLevel(toPush);
      }
    }

    // Pull all entities (including deps) in topological order
    final pullLevels = _topologicalSort(closureList, forward: true);
    for (final level in pullLevels) {
      await _executePullLevel(level);
    }

    _syncOrchestratorLog.fine('Completed syncSubset');
  }

  /// Pushes a single entity, ensuring dependencies are satisfied
  ///
  /// If the entity is already being pushed, returns the in-flight completer.
  /// If dependencies are being pushed, waits for them to complete first.
  Future<bool> push(SyncEntity entity) async {
    // Check if already pushing
    if (_pushCompleters.containsKey(entity)) {
      _syncOrchestratorLog.fine(
        'Push already in progress for ${entity.debugName}, waiting...',
      );
      return _pushCompleters[entity]!.future;
    }

    final completer = Completer<bool>();
    _pushCompleters[entity] = completer;
    final sw = Stopwatch()..start();

    try {
      // Abort if the Store has been closed/removed during an async gap
      if (!Store.isAvailable) {
        completer.complete(false);
        return false;
      }

      // Ensure dependencies are pushed first
      for (final dep in entity.dependsOn) {
        _syncOrchestratorLog.fine(
          'Ensuring dependency ${dep.debugName} is pushed before pushing ${entity.debugName}',
        );
        // Recursively push each dependency (will use existing completer if already in progress)
        await push(dep);
      }
      final depsMs = sw.elapsedMilliseconds;

      // Re-check after awaiting dependencies — Store may have closed
      if (!Store.isAvailable) {
        completer.complete(false);
        return false;
      }

      final success = await entity.pushFn();
      if (syncPerfLog) {
        _syncOrchestratorLog.info(
          'push ${entity.debugName}: ${sw.elapsedMilliseconds}ms '
          '(deps ${depsMs}ms, self ${sw.elapsedMilliseconds - depsMs}ms, '
          '${success ? 'ok' : 'failed'})',
        );
      }
      completer.complete(success);
      return success;
    } catch (e, stackTrace) {
      _trackRateLimitIfNeeded(e);

      if (!_isExpectedError(e)) {
        _syncOrchestratorLog.severe(
          'Error pushing ${entity.debugName}',
          e,
          stackTrace,
        );
        Tracker.trackError(
          entity.debugName,
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: stackTrace.toString(),
          context: 'sync_orchestrator_push',
        );
        completer.completeError(e, stackTrace);
      } else {
        // Expected errors (network, auth, rate limit): warn without stack trace
        _syncOrchestratorLog.warning(
          'Error pushing ${entity.debugName}: $e',
        );
        completer.complete(false);
      }
      return false;
    } finally {
      // During [syncAll], leave the completer in place so dep-walks in
      // later levels reuse the result (the recursive `push(dep)` chain
      // would otherwise re-push every parent in every level). Cleared by
      // syncAll's own finally.
      if (!_syncAllInProgress) {
        _pushCompleters.remove(entity);
      }
    }
  }

  /// Pulls a single entity
  ///
  /// If the entity is already being pulled, marks it dirty (so a follow-up
  /// pull runs after the current one completes) and returns the in-flight
  /// completer.
  Future<void> pull(SyncEntity entity) async {
    // Check if already pulling
    if (_pullCompleters.containsKey(entity)) {
      _pullDirty.add(entity);
      _syncOrchestratorLog.fine(
        'Pull already in progress for ${entity.debugName}, '
        'marked dirty for follow-up pull',
      );
      return _pullCompleters[entity]!.future;
    }

    final completer = Completer<void>();
    _pullCompleters[entity] = completer;
    final sw = Stopwatch()..start();

    try {
      // Abort if the Store has been closed/removed during an async gap
      if (!Store.isAvailable) return;

      await entity.pullFn();
      if (syncPerfLog) {
        _syncOrchestratorLog.info(
          'pull ${entity.debugName}: ${sw.elapsedMilliseconds}ms',
        );
      }
      completer.complete();
    } catch (e, stackTrace) {
      _trackRateLimitIfNeeded(e);

      if (!_isExpectedError(e)) {
        _syncOrchestratorLog.severe(
          'Error pulling ${entity.debugName}',
          e,
          stackTrace,
        );
        Tracker.trackError(
          entity.debugName,
          errorType: e.runtimeType.toString(),
          errorMessage: e.toString(),
          stackTrace: stackTrace.toString(),
          context: 'sync_orchestrator_pull',
        );
        completer.completeError(e, stackTrace);
      } else {
        // Expected errors (network, auth, rate limit): warn without stack trace
        _syncOrchestratorLog.warning(
          'Error pulling ${entity.debugName}: $e',
        );
        completer.complete();
      }
    } finally {
      _pullCompleters.remove(entity);
    }

    // If broadcasts arrived during the pull, run a fresh pull immediately so
    // mid-pull updates aren't stranded until the next broadcast cycle. Don't
    // await — the original caller resolves on the in-flight completer above.
    if (_pullDirty.remove(entity) && Store.isAvailable) {
      _syncOrchestratorLog.fine(
        'Re-pulling ${entity.debugName} (dirty during in-flight pull)',
      );
      Future<void>.microtask(() => pull(entity));
    }

    return completer.future;
  }

  // ============================================================================
  // INTERNAL METHODS
  // ============================================================================

  /// Executes a pull level (all entities in parallel)
  Future<void> _executePullLevel(List<SyncEntity> entities) async {
    await Future.wait(
      entities.map((e) => pull(e)),
      eagerError: false, // Continue even if some fail
    );
  }

  /// Executes a push level (all entities in parallel)
  Future<void> _executePushLevel(List<SyncEntity> entities) async {
    await Future.wait(
      entities.map((e) => push(e)),
      eagerError: false, // Continue even if some fail
    );
  }

  /// Determines if an error is expected/transient and should not be reported to PostHog
  ///
  /// Returns true for:
  /// - Network errors (expected during offline periods)
  /// - Auth errors (handled by automatic sign-out flow)
  /// - 429 rate limit errors (transient, handled by backoff)
  ///
  /// Returns false for:
  /// - API errors (unexpected)
  /// - RLS violations (app bugs)
  /// - Unknown exceptions (need investigation)
  bool _isExpectedError(dynamic error) {
    // Network errors are expected during offline periods
    if (error is NetworkException) return true;
    if (error is SocketException) return true;
    if (error is HttpException) return true;

    // Auth errors are handled by sign-out flow and tracked elsewhere
    if (Store._isAuthError(error)) return true;

    // 429 rate limit errors are transient and handled by backoff
    if (error is ApiException && error.statusCode == 429) return true;

    // All other errors should be reported
    return false;
  }

  /// Tracks a 429 rate limit event and increases cooldown (exponential, max 60s)
  void _trackRateLimitIfNeeded(dynamic error) {
    if (error is ApiException && error.statusCode == 429) {
      _lastRateLimitAt = DateTime.now();
      // Double cooldown on each 429, capped at 60s
      _rateLimitCooldown = Duration(
        seconds: (_rateLimitCooldown.inSeconds * 2).clamp(5, 60),
      );
      _syncOrchestratorLog.warning(
        'Rate limited (429). Cooldown: ${_rateLimitCooldown.inSeconds}s',
      );
    }
  }

  /// Waits out any active 429 cooldown period, resets cooldown on success
  Future<void> _waitForRateLimitCooldown() async {
    if (_lastRateLimitAt == null) return;

    final elapsed = DateTime.now().difference(_lastRateLimitAt!);
    if (elapsed < _rateLimitCooldown) {
      final remaining = _rateLimitCooldown - elapsed;
      _syncOrchestratorLog.fine(
        'Waiting ${remaining.inSeconds}s for rate limit cooldown',
      );
      await Future<void>.delayed(remaining);
    }

    // Reset cooldown after waiting
    _lastRateLimitAt = null;
    _rateLimitCooldown = const Duration(seconds: 5);
  }

  /// Computes pull levels using topological sort (parent → child order)
  ///
  /// Returns a list of levels, where each level contains entities that can be
  /// pulled in parallel. Dependencies are guaranteed to be in earlier levels.
  List<List<SyncEntity>> _computePullLevels() {
    return _topologicalSort(allEntities, forward: true);
  }

  /// Computes push levels using topological sort (parent → child order)
  ///
  /// Returns a list of levels, where each level contains entities that can be
  /// pushed in parallel. Dependencies are guaranteed to be in earlier levels.
  /// Push order is the same as pull order: parents must exist before children.
  List<List<SyncEntity>> _computePushLevels() {
    return _topologicalSort(allEntities, forward: true);
  }

  /// Performs topological sort using Kahn's algorithm
  ///
  /// If [forward] is true, returns parent→child order (for both pull and push).
  /// If [forward] is false, returns child→parent order (currently unused, kept for flexibility).
  ///
  /// Returns levels where entities in each level can be processed in parallel.
  List<List<SyncEntity>> _topologicalSort(
    List<SyncEntity> entities, {
    required bool forward,
  }) {
    // Build dependency graph
    final inDegree = <SyncEntity, int>{};
    final dependents = <SyncEntity, Set<SyncEntity>>{};

    for (final entity in entities) {
      inDegree[entity] = 0;
      dependents[entity] = {};
    }

    for (final entity in entities) {
      for (final dep in entity.dependsOn) {
        if (forward) {
          // For pull and push (forward): entity depends on dep
          // dep must be processed before entity (parent before child)
          inDegree[entity] = (inDegree[entity] ?? 0) + 1;
          dependents[dep]!.add(entity);
        } else {
          // Reverse order (currently unused): entity before dep
          // entity must be processed before its dependencies (child before parent)
          inDegree[dep] = (inDegree[dep] ?? 0) + 1;
          dependents[entity]!.add(dep);
        }
      }
    }

    // Kahn's algorithm - process level by level
    final levels = <List<SyncEntity>>[];
    var queue = entities.where((e) => inDegree[e] == 0).toList();

    while (queue.isNotEmpty) {
      // All entities in queue have no remaining dependencies - they can run in parallel
      levels.add(List.from(queue));

      final nextQueue = <SyncEntity>[];
      for (final entity in queue) {
        for (final dependent in dependents[entity]!) {
          inDegree[dependent] = (inDegree[dependent] ?? 0) - 1;
          if (inDegree[dependent] == 0) {
            nextQueue.add(dependent);
          }
        }
      }
      queue = nextQueue;
    }

    // Check for circular dependencies
    final processedCount = levels.fold<int>(
      0,
      (sum, level) => sum + level.length,
    );
    if (processedCount < entities.length) {
      final unprocessed = entities.where(
        (e) => !levels.any((level) => level.contains(e)),
      );
      throw StateError(
        'Circular dependency detected in sync entities: $unprocessed',
      );
    }

    return levels;
  }
}
