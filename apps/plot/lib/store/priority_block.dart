part of 'store.dart';

typedef PriorityBlockId = Uuid;

/// A `priority_block` row records that a priority's order_value applies
/// from `effectiveAt` forward. Used by the agenda renderer to look up the
/// effective order of a priority block at any moment in time.
///
/// Multiple rows per priority form a timeline; the latest row whose
/// `effectiveAt <= moment` determines the order at that moment. Falls
/// back to a reasonable default (e.g. priority.order) when no rows exist.
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
        archivedAt: row.archivedAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        pending: row.pending,
      );

  factory PriorityBlock.fromStore(PriorityBlockRow row) =>
      PriorityBlock._fromRow(row);

  /// Build a fresh PriorityBlock for a priority, taking effect at [effectiveAt]
  /// with [orderValue]. The id is auto-generated; createdAt/updatedAt are now.
  factory PriorityBlock({
    required PriorityId priorityId,
    required Order orderValue,
    required DateTime effectiveAt,
  }) {
    final now = DateTime.now();
    return PriorityBlock._fromRow(
      PriorityBlockRow(
        id: Uuid.generate(),
        priorityId: priorityId,
        createdBy: Base.userId,
        orderValue: orderValue,
        effectiveAt: effectiveAt,
        archivedAt: null,
        createdAt: now,
        updatedAt: now,
      ),
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


  /// Persist this row locally and queue a push. Set [archivePast] to true to
  /// soft-archive every existing non-archived row for the same priority
  /// whose effective_at is earlier than this row's effective_at — used when
  /// reordering in the do-now slot. Each archived row is pushed to the
  /// server as a regular update with archived_at set.
  Future<void> save({bool archivePast = false}) async {
    if (archivePast) {
      final past = await (Store.get.select(table)
            ..where(
              (t) =>
                  t.priorityId.equals(priorityId.toBytes()) &
                  t.effectiveAt.isSmallerThanValue(effectiveAt) &
                  t.archivedAt.isNull(),
            ))
          .get();
      for (final row in past) {
        final archived = row.copyWith(
          archivedAt: Value(DateTime.now()),
          updatedAt: DateTime.now(),
        );
        await Store.get.save(
          table,
          archived.toCompanion(false),
          PriorityBlocksBase(),
        );
      }
    }
    await Store.get.save(
      table,
      copyWith(updatedAt: DateTime.now()).toCompanion(false),
      PriorityBlocksBase(),
    );
  }
}
