import 'dart:async';

import 'package:drift/drift.dart';

/// A read-pool query executor: writes (and anything inside a transaction) go
/// to [write]; SELECTs outside transactions are distributed across [reads].
///
/// This is functionally drift 2.33's `MultiExecutor.withReadPool` with one
/// fix: **queued SELECTs run in the [Zone] captured when they were
/// enqueued.** Drift's `_QueryExecutorPool._run()` dequeues the next pending
/// select from the `finally` continuation of the previous select — i.e.
/// inside the *previous* query's cancellation zone (drift's stream queries
/// wrap fetches in `runZoned` with a `CancellationToken` zone value, and the
/// isolate client's `runSelect` reads `Zone.current` for `checkIfCancelled`
/// / `doOnCancellation`). Under a switch-burst that overflows the pool this
/// mis-attribution made unrelated queued queries throw "Operation was
/// cancelled" (observed breaking sync pushes and wedging the feed streams
/// for tens of seconds). Capturing the zone at enqueue time restores the
/// exact zone semantics a single-connection executor would have had.
class ZonedReadPoolExecutor extends QueryExecutor {
  ZonedReadPoolExecutor({
    required List<QueryExecutor> reads,
    required QueryExecutor write,
  }) :
       // ignore: prefer_initializing_formals
       _write = write,
       _pool = _ZonedExecutorPool(reads);

  final QueryExecutor _write;
  final _ZonedExecutorPool _pool;

  @override
  SqlDialect get dialect => _write.dialect;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    // The write connection must open first: it runs migrations, while the
    // reading connections only set the user version (mirrors drift's
    // MultiExecutor ordering).
    return await _write.ensureOpen(user) &&
        await _pool.ensureOpen(_NoMigrationsWrapper(user));
  }

  @override
  QueryExecutor beginExclusive() => _write.beginExclusive();

  @override
  TransactionExecutor beginTransaction() => _write.beginTransaction();

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _write.runBatched(statements);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _write.runCustom(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _write.runDelete(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _write.runInsert(statement, args);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) {
    // RETURNING statements write even though they surface as selects — they
    // must run on the write connection (same routing as drift's pool).
    if (statement.contains('RETURNING')) {
      return _write.runSelect(statement, args);
    }
    return _pool.runSelect(statement, args);
  }

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _write.runUpdate(statement, args);

  @override
  Future<void> close() async {
    await _write.close();
    await _pool.close();
  }
}

class _PendingSelect {
  _PendingSelect(this.statement, this.args)
    : zone = Zone.current,
      completer = Completer<List<Map<String, Object?>>>();

  final String statement;
  final List<Object?> args;

  /// The zone active when the select was requested. Holds the requester's
  /// own cancellation token (if any) — the select must execute here, not in
  /// whatever zone happens to free up a pooled executor.
  final Zone zone;

  final Completer<List<Map<String, Object?>>> completer;
}

class _ZonedExecutorPool {
  _ZonedExecutorPool(this._executors) : _idle = [..._executors];

  final List<QueryExecutor> _executors;
  final List<QueryExecutor> _idle;
  final List<_PendingSelect> _queue = [];

  Future<bool> ensureOpen(QueryExecutorUser user) async {
    final results = await Future.wait(
      _executors.map((executor) => executor.ensureOpen(user)),
    );
    return results.every((opened) => opened);
  }

  Future<void> close() =>
      Future.wait(_executors.map((executor) => executor.close()));

  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) {
    if (_executors.length == 1) {
      return _executors.single.runSelect(statement, args);
    }

    final pending = _PendingSelect(statement, args);
    _queue.add(pending);
    _run();
    return pending.completer.future;
  }

  void _run() {
    if (_queue.isEmpty || _idle.isEmpty) return;

    final executor = _idle.removeAt(0);
    final pending = _queue.removeAt(0);

    pending.completer.complete(
      Future.sync(() async {
        try {
          // Run in the requester's zone so the isolate client's
          // checkIfCancelled / doOnCancellation see the correct
          // cancellation token. See the class doc.
          return await pending.zone.run(
            () => executor.runSelect(pending.statement, pending.args),
          );
        } finally {
          _idle.add(executor);
          _run();
        }
      }),
    );
  }
}

class _NoMigrationsWrapper extends QueryExecutorUser {
  _NoMigrationsWrapper(this.inner);

  final QueryExecutorUser inner;

  @override
  int get schemaVersion => inner.schemaVersion;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {
    // Migrations already ran on the write connection.
  }
}
