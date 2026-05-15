part of 'store.dart';

typedef PriorityBlockId = Uuid;

/// A `priority_block` row holds a priority's `order_value` and pending
/// `duration` at a given `effectiveAt`. Used by the agenda renderer to
/// look up these values at any moment in time.
///
/// Every row uses a real block-start timestamp as `effectiveAt`. The
/// duration resolver ([resolveBlockDurations]) and order resolver
/// ([effectivePriorityOrderAt]) each pick the latest eligible row.
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
  /// Pending planned duration for the priority at this `effective_at`.
  /// Resolved per agenda block via [resolveBlockDurations]. Stored
  /// locally as seconds and serialized to/from Postgres `interval` via
  /// [IntervalConverter].
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

/// Stream every `priority_block` row that the agenda might care about,
/// grouped by priority id. Returns a UNION of:
///   1. All non-archived rows with `effective_at >= todayMidnight`
///      (the forward window — today, future, and pre-planned changes).
///   2. The per-priority carry-forward anchor: the most-recent
///      non-archived row strictly before `todayMidnight`, so the
///      cumulative order resolver still has a baseline once historical
///      rows fall out of the forward window.
///
/// Anchor rows participate in [effectivePriorityOrderAt] only;
/// [resolveBlockDurations] filters them out and ignores their
/// `duration` values.
///
/// Top-level (rather than a method on [PriorityBlock]) so callers that
/// hide [PriorityBlock] to disambiguate against agenda_model's UI block
/// can still reach the helper.
Stream<Map<PriorityId, List<PriorityBlockRow>>>
    streamPriorityBlocksGroupedByPriority() {
  final db = Store.get;
  final now = DateTime.now();
  final todayMidnight = DateTime(now.year, now.month, now.day);

  final query = db.customSelect(
    '''
SELECT * FROM priority_blocks
WHERE archived_at IS NULL AND effective_at >= ?1

UNION ALL

SELECT pb.* FROM priority_blocks pb
WHERE pb.archived_at IS NULL
  AND pb.effective_at < ?1
  AND pb.effective_at = (
    SELECT MAX(effective_at) FROM priority_blocks
    WHERE priority_id = pb.priority_id
      AND archived_at IS NULL
      AND effective_at < ?1
  )
''',
    variables: [Variable.withDateTime(todayMidnight)],
    readsFrom: {db.priorityBlocks},
  );

  return query.watch().map((rows) {
    final out = <PriorityId, List<PriorityBlockRow>>{};
    for (final r in rows) {
      final row = db.priorityBlocks.map(r.data);
      out.putIfAbsent(row.priorityId, () => <PriorityBlockRow>[]).add(row);
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

/// Pure function. Returns a map from agenda block id to the duration
/// that block should display.
///
/// Walks the priority's blocks in chronological order; each block
/// consumes every unconsumed in-window row whose `effective_at <=
/// block.start`, and gets the latest such row's `duration`. Rows whose
/// `effective_at` is strictly before [todayMidnight] are ignored (they
/// serve only as the order resolver's anchor and never contribute a
/// duration). Archived rows and rows whose `duration` is null or non-positive are skipped.
///
/// [blocks] must be sorted ascending by `start`.
Map<String, Duration?> resolveBlockDurations({
  required DateTime todayMidnight,
  required List<({String id, DateTime start})> blocks,
  required Iterable<PriorityBlockRow> blocksForPriority,
}) {
  final rows = blocksForPriority
      .where((r) => r.archivedAt == null)
      .where((r) => r.duration != null && r.duration! > Duration.zero)
      .where((r) => !r.effectiveAt.isBefore(todayMidnight))
      .toList()
    ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));

  assert(() {
    for (var i = 1; i < blocks.length; i++) {
      if (blocks[i].start.isBefore(blocks[i - 1].start)) {
        return false;
      }
    }
    return true;
  }(), 'blocks must be sorted ascending by start');

  final out = <String, Duration?>{};
  var rowIdx = 0;
  for (final b in blocks) {
    Duration? best;
    while (rowIdx < rows.length &&
        !rows[rowIdx].effectiveAt.isAfter(b.start)) {
      best = rows[rowIdx].duration;
      rowIdx++;
    }
    out[b.id] = best;
  }
  return out;
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

  /// Upsert a `priority_block` row for [priorityId] at `effective_at =
  /// blockStart`, carrying [newDuration]. Carries the priority's
  /// effective order at [blockStart] into `order_value` so the row also
  /// participates in the order timeline (same convention reorders use).
  ///
  /// Local-first: upserts the row at `(priorityId, blockStart)`; the
  /// sync orchestrator pushes it on the next push window.
  ///
  /// Semantics:
  ///   - normalize null/≤0 → null,
  ///   - if normalized equals the current row's duration, no-op,
  ///   - if normalized is null, soft-archive the row at this slot,
  ///   - otherwise upsert in place at `(priorityId, blockStart)`.
  static Future<void> setBlockDuration({
    required PriorityId priorityId,
    required DateTime blockStart,
    required Duration? newDuration,
  }) async {
    if (!Store.isAvailable) return;
    final normalized =
        (newDuration == null || newDuration <= Duration.zero) ? null : newDuration;

    final rows = await (Store.get.select(table)
          ..where((t) => t.priorityId.equals(priorityId.toBytes())))
        .get();

    final slotRow = rows.firstWhereOrNull(
      (r) => r.effectiveAt.isAtSameMomentAs(blockStart),
    );
    final currentDuration =
        slotRow?.archivedAt == null ? slotRow?.duration : null;
    if (normalized == currentDuration) return;

    final now = DateTime.now();

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
      moment: blockStart,
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
            effectiveAt: blockStart,
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
