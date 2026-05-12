part of 'store.dart';

typedef PriorityBlockId = Uuid;

/// A `priority_block` row holds a priority's `order_value` and pending
/// `duration` at a given `effectiveAt`. Used by the agenda renderer to
/// look up these values at any moment in time.
///
/// Two conventions for `effectiveAt`:
///   * [kCurrentEffectiveAt] (epoch) — the canonical "current" row.
///     Adjustments to pending duration or order upsert onto this single
///     sentinel row per priority; there is no timeline of past changes.
///   * A future timestamp — a planned change that takes effect at that
///     moment (the resolver picks the latest row whose `effectiveAt <=
///     moment`).
///
/// Falls back to `priority.order_value` when no row exists.
@DataClassName('PriorityBlockRow')
class PriorityBlocks extends Table
    with SyncableTable, UuidTable, CreatedTable, DeletableTable {
  BlobColumn get priorityId =>
      blob().map(const UuidConverter()).references(Priorities, #id)();
  BlobColumn get createdBy =>
      blob().map(const UuidConverter()).nullable()();
  RealColumn get orderValue =>
      real().map(const OrderConverter())();
  DateTimeColumn get effectiveAt =>
      dateTime().map(const LocalDateTimeConverter())();
  /// Pending planned duration for the priority as of `effectiveAt`. NULL
  /// or zero means "no pending" (priority drops out of the agenda cascade).
  /// Resolved via [effectivePriorityDurationAt]. Stored locally as seconds
  /// and serialized to/from Postgres `interval` via [IntervalConverter].
  IntColumn get duration =>
      integer().nullable().map(const IntervalConverter())();
}

class PriorityBlocksBase extends BaseTable {
  PriorityBlocksBase()
    : super(
        table: 'user_priority_block',
        syncEndpoint: 'priority-blocks',
        name: 'priority_blocks',
      );

  @override
  Insertable<PriorityBlockRow> fromBase(Map<String, dynamic> json) {
    json.remove('updated_by');
    return PriorityBlockRow.fromJson(json);
  }
}

/// Stream every non-archived priority_block row, grouped by priority id.
/// Convenient for feeding [AgendaBuilder.build]'s
/// `priorityBlocksByPriority` parameter.
///
/// Top-level (rather than a method on [PriorityBlock]) so callers that
/// hide [PriorityBlock] to disambiguate against agenda_model's UI block
/// can still reach the helper.
Stream<Map<PriorityId, List<PriorityBlockRow>>>
    streamPriorityBlocksGroupedByPriority() {
  final query = Store.get.select(Store.get.priorityBlocks)
    ..where((t) => t.archivedAt.isNull());
  return query.watch().map((rows) {
    final out = <PriorityId, List<PriorityBlockRow>>{};
    for (final r in rows) {
      out.putIfAbsent(r.priorityId, () => <PriorityBlockRow>[]).add(r);
    }
    return out;
  });
}

/// Effective order resolver — pure function, no DB.
///
/// Given a list of priority_block rows for a single priority (any order),
/// returns the order_value in effect at [moment]. Returns [fallback] if
/// no row's effective_at <= moment (e.g. priority was just created).
double effectivePriorityOrderAt({
  required DateTime moment,
  required Iterable<PriorityBlockRow> blocksForPriority,
  required double fallback,
}) {
  PriorityBlockRow? best;
  for (final row in blocksForPriority) {
    if (row.archivedAt != null) continue;
    if (row.effectiveAt.isAfter(moment)) continue;
    if (best == null || row.effectiveAt.isAfter(best.effectiveAt)) {
      best = row;
    }
  }
  return best?.orderValue.value ?? fallback;
}

/// Canonical "current" effective_at for the priority_block row that
/// carries a priority's order_value and pending duration right now.
/// Adjustments to current pending upsert onto this single sentinel row
/// keyed by `(priority_id, effective_at)`. Future-dated rows represent
/// planned changes that take effect at their `effective_at`.
final DateTime kCurrentEffectiveAt = DateTime.utc(1970, 1, 1);

/// Effective pending-duration resolver — pure function, no DB.
///
/// Returns the priority's pending planned duration at [moment]: the latest
/// non-archived priority_block row with a non-null `duration` whose
/// `effective_at <= moment` wins. Rows without `duration` (e.g. future
/// reorder anchors that only carry `order_value`) don't override pending.
/// Returns null when no row contributes a duration (priority drops out of
/// the agenda cascade).
Duration? effectivePriorityDurationAt({
  required DateTime moment,
  required Iterable<PriorityBlockRow> blocksForPriority,
}) {
  PriorityBlockRow? best;
  for (final row in blocksForPriority) {
    if (row.archivedAt != null) continue;
    if (row.effectiveAt.isAfter(moment)) continue;
    if (row.duration == null) continue;
    if (best == null || row.effectiveAt.isAfter(best.effectiveAt)) {
      best = row;
    }
  }
  final d = best?.duration;
  if (d == null || d <= Duration.zero) return null;
  return d;
}

/// Domain wrapper around a PriorityBlockRow with helpers for the common
/// sync/save flows. Mirrors the Priority/Session pattern.
class PriorityBlock extends PriorityBlockRow {
  static TableInfo<PriorityBlocks, PriorityBlockRow> get table =>
      Store.get.priorityBlocks;

  static Future<bool> push() =>
      Store.get.push(table, PriorityBlocksBase());
  static Future<void> pull() async =>
      await Store.get.pull(table, PriorityBlocksBase());

  PriorityBlock._fromRow(PriorityBlockRow row)
    : super(
        id: row.id,
        priorityId: row.priorityId,
        createdBy: row.createdBy,
        orderValue: row.orderValue,
        effectiveAt: row.effectiveAt,
        duration: row.duration,
        archivedAt: row.archivedAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        pending: row.pending,
      );

  factory PriorityBlock.fromStore(PriorityBlockRow row) =>
      PriorityBlock._fromRow(row);

  /// Build a fresh PriorityBlock for a priority, taking effect at [effectiveAt]
  /// with [orderValue]. The id is auto-generated; createdAt/updatedAt are now.
  /// [duration] carries the priority's pending planned time as of
  /// [effectiveAt]; pass null for "no change to pending".
  factory PriorityBlock({
    required PriorityId priorityId,
    required Order orderValue,
    required DateTime effectiveAt,
    Duration? duration,
  }) {
    final now = DateTime.now();
    return PriorityBlock._fromRow(
      PriorityBlockRow(
        id: Uuid.generate(),
        priorityId: priorityId,
        createdBy: Base.userId,
        orderValue: orderValue,
        effectiveAt: effectiveAt,
        duration: duration,
        archivedAt: null,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Set the priority's current pending duration to [newDuration].
  /// Local-first: upserts the canonical row at [kCurrentEffectiveAt];
  /// the sync orchestrator pushes it whenever the next push window opens.
  ///
  /// Semantics:
  ///   - normalize null/≤0 → null,
  ///   - if normalized equals the current duration, no-op,
  ///   - if normalized is null, soft-archive the canonical row,
  ///   - otherwise upsert the canonical row in place, carrying forward
  ///     the priority's effective order so reorders aren't lost.
  static Future<void> setPendingDuration(
    PriorityId priorityId,
    Duration? newDuration,
  ) async {
    if (!Store.isAvailable) return;
    final normalized =
        (newDuration == null || newDuration <= Duration.zero) ? null : newDuration;

    final rows = await (Store.get.select(table)
          ..where((t) => t.priorityId.equals(priorityId.toBytes())))
        .get();

    // The (priority_id, effective_at) unique index includes archived
    // rows, so look up the slot regardless of archive state and update
    // in place rather than inserting a new id that would collide.
    final slotRow = rows.firstWhereOrNull(
      (r) => r.effectiveAt.isAtSameMomentAs(kCurrentEffectiveAt),
    );
    final currentDuration = slotRow?.archivedAt == null ? slotRow?.duration : null;

    final now = DateTime.now();
    // Past-dated, non-epoch rows that still carry a `duration` mask the
    // canonical row in [effectivePriorityDurationAt] (which picks the
    // latest `effective_at <= now`). Archive them so the epoch row is
    // authoritative for "current". Future-dated rows are left alone —
    // they're planned changes that should still take effect.
    final maskingRows = rows
        .where((r) =>
            r.archivedAt == null &&
            r.duration != null &&
            !r.effectiveAt.isAtSameMomentAs(kCurrentEffectiveAt) &&
            !r.effectiveAt.isAfter(now))
        .toList();

    if (maskingRows.isEmpty && normalized == currentDuration) return;

    for (final row in maskingRows) {
      final archived = row.copyWith(
        archivedAt: Value(now),
        updatedAt: now,
      );
      await Store.get.save(
        table,
        archived.toCompanion(false),
        PriorityBlocksBase(),
      );
    }

    if (normalized == null) {
      if (slotRow == null || slotRow.archivedAt != null) return;
      final archived = slotRow.copyWith(
        archivedAt: Value(now),
        updatedAt: now,
      );
      await Store.get.save(
        table,
        archived.toCompanion(false),
        PriorityBlocksBase(),
      );
      return;
    }

    final inheritedOrder = effectivePriorityOrderAt(
      moment: now,
      blocksForPriority: rows,
      fallback: 0,
    );

    final row = slotRow != null
        ? slotRow.copyWith(
            orderValue: Order(inheritedOrder),
            duration: Value(normalized),
            archivedAt: const Value(null),
            updatedAt: now,
          )
        : PriorityBlockRow(
            id: Uuid.generate(),
            priorityId: priorityId,
            createdBy: Base.userId,
            orderValue: Order(inheritedOrder),
            effectiveAt: kCurrentEffectiveAt,
            duration: normalized,
            archivedAt: null,
            createdAt: now,
            updatedAt: now,
          );
    await Store.get.save(
      table,
      row.toCompanion(false),
      PriorityBlocksBase(),
    );
  }

  /// Stream every non-archived priority_block row for the current user.
  /// Used by PriorityBloc to keep an in-memory map of orderings.
  static Stream<List<PriorityBlock>> streamAll() {
    final query = Store.get.select(table)..where((t) => t.archivedAt.isNull());
    return query
        .watch()
        .map((rows) => rows.map(PriorityBlock.fromStore).toList());
  }


  /// Persist this row locally and queue a push.
  ///
  /// Upserts on `(priority_id, effective_at)`: if any row (archived or
  /// not) already occupies the same slot, this row's id is rewritten to
  /// that row's id so the write updates in place rather than tripping
  /// the SQLite unique constraint. The server's `upsert_priority_block`
  /// RPC applies the same conflict policy.
  Future<void> save() async {
    final existing = await (Store.get.select(table)
          ..where((t) =>
              t.priorityId.equals(priorityId.toBytes()) &
              t.effectiveAt.equals(effectiveAt) &
              t.id.isNotValue(id.toBytes()))
          ..limit(1))
        .getSingleOrNull();
    final effectiveId = existing?.id ?? id;
    final row = copyWith(id: effectiveId, updatedAt: DateTime.now());
    await Store.get.save(
      table,
      row.toCompanion(false),
      PriorityBlocksBase(),
    );
  }
}
