part of 'store.dart';

final _syncOrchestratorLog = Logger('plot.sync_orchestrator');

/// Orchestrates sync operations across all entities with dependency awareness.
///
/// Provides:
/// - Type-safe entity references (SyncOrchestrator.activity, etc.)
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

  // ============================================================================
  // STATIC ENTITY DEFINITIONS (type-safe!)
  // ============================================================================

  /// Actor entity (read-only, no dependencies)
  static final actor = SyncEntity(
    debugName: 'actor',
    dependsOn: [],
    pushFn: () async => true, // Read-only, skip push
    pullFn: Actor.pull,
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

  /// PriorityUser entity (depends on priority and actor)
  static final priorityUser = SyncEntity(
    debugName: 'priority_user',
    dependsOn: [priority, actor],
    pushFn: PriorityUser.push,
    pullFn: PriorityUser.pull,
  );

  /// PriorityTwist entity (depends on priority)
  static final priorityTwist = SyncEntity(
    debugName: 'priority_twist',
    dependsOn: [priority],
    pushFn: PriorityTwist.push,
    pullFn: () async {
      await PriorityTwist.pullInitial();
      await PriorityTwist.pullUpdates();
    },
  );

  /// Activity entity (depends on priority and actor)
  /// Note: Activity.push() and Activity.pull() also handle ActivityExceptions and ActivityTags
  static final activity = SyncEntity(
    debugName: 'activity',
    dependsOn: [priority, actor],
    pushFn: Activity.push,
    pullFn: () async {
      await Activity.pullInitial();
      await Activity.pull();
    },
  );

  /// Session entity (depends on priority)
  static final session = SyncEntity(
    debugName: 'session',
    dependsOn: [priority],
    pushFn: Session.push,
    pullFn: Session.pull,
  );

  /// Note entity (depends on activity and actor)
  /// Note: Note.push(), Note.pullInitial(), and Note.pullUpdates() also handle NoteTags
  static final note = SyncEntity(
    debugName: 'note',
    dependsOn: [activity, actor],
    pushFn: Note.push,
    pullFn: () async {
      await Note.pullUpdates();
    },
  );

  /// All syncable entities in dependency order (for iteration)
  static final allEntities = [
    actor,
    userSettings,
    priority,
    priorityUser,
    priorityTwist,
    activity,
    session,
    note,
  ];

  // ============================================================================
  // PUBLIC API
  // ============================================================================

  /// Maps database table names to SyncEntity instances
  ///
  /// Returns null for unknown table names.
  static SyncEntity? getEntityByTableName(String table) {
    return switch (table) {
      'actor' => actor,
      'user_settings' => userSettings,
      'priority' => priority,
      'priority_user' => priorityUser,
      'priority_twist' => priorityTwist,
      'activity' || 'activity_read' => activity,
      'session' => session,
      'note' => note,
      _ => null,
    };
  }

  /// Syncs all entities: pull all (parents→children), then push all (children→parents)
  ///
  /// This replaces the old _syncAll() method with a dependency-aware version.
  Future<void> syncAll() async {
    _syncOrchestratorLog.info('Starting syncAll: pull all → push all');

    // Phase 1: Pull all (parents → children)
    final pullLevels = _computePullLevels();
    _syncOrchestratorLog.fine(
      'Pull levels: ${pullLevels.map((l) => l.map((e) => e.debugName).toList()).toList()}',
    );

    for (var i = 0; i < pullLevels.length; i++) {
      final level = pullLevels[i];
      _syncOrchestratorLog.fine(
        'Pulling level $i: ${level.map((e) => e.debugName).toList()}',
      );
      await _executePullLevel(level);
    }

    // Phase 2: Push all (children → parents)
    final pushLevels = _computePushLevels();
    _syncOrchestratorLog.fine(
      'Push levels: ${pushLevels.map((l) => l.map((e) => e.debugName).toList()).toList()}',
    );

    for (var i = 0; i < pushLevels.length; i++) {
      final level = pushLevels[i];
      _syncOrchestratorLog.fine(
        'Pushing level $i: ${level.map((e) => e.debugName).toList()}',
      );
      await _executePushLevel(level);
    }

    _syncOrchestratorLog.info('Completed syncAll');
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

    try {
      // Ensure dependencies are pushed first
      for (final dep in entity.dependsOn) {
        _syncOrchestratorLog.fine(
          'Ensuring dependency ${dep.debugName} is pushed before pushing ${entity.debugName}',
        );
        // Recursively push each dependency (will use existing completer if already in progress)
        await push(dep);
      }

      _syncOrchestratorLog.fine('Pushing ${entity.debugName}');
      final success = await entity.pushFn();
      _syncOrchestratorLog.fine(
        'Push ${entity.debugName}: ${success ? 'success' : 'failed'}',
      );
      completer.complete(success);
      return success;
    } catch (e, stackTrace) {
      _syncOrchestratorLog.severe(
        'Error pushing ${entity.debugName}',
        e,
        stackTrace,
      );
      completer.completeError(e, stackTrace);
      return false;
    } finally {
      _pushCompleters.remove(entity);
    }
  }

  /// Pulls a single entity
  ///
  /// If the entity is already being pulled, returns the in-flight completer.
  Future<void> pull(SyncEntity entity) async {
    // Check if already pulling
    if (_pullCompleters.containsKey(entity)) {
      _syncOrchestratorLog.fine(
        'Pull already in progress for ${entity.debugName}, waiting...',
      );
      return _pullCompleters[entity]!.future;
    }

    final completer = Completer<void>();
    _pullCompleters[entity] = completer;

    try {
      _syncOrchestratorLog.fine('Pulling ${entity.debugName}');
      await entity.pullFn();
      _syncOrchestratorLog.fine('Pulled ${entity.debugName}');
      completer.complete();
    } catch (e, stackTrace) {
      _syncOrchestratorLog.severe(
        'Error pulling ${entity.debugName}',
        e,
        stackTrace,
      );
      completer.completeError(e, stackTrace);
    } finally {
      _pullCompleters.remove(entity);
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
