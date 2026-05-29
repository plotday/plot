import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart' hide PriorityBlock;
import 'package:plot/store/store.dart' as store show PriorityBlock;
import 'package:plot/widget/schedule_focus_modal.dart';
import 'package:plot/widget/widget.dart';

import 'base.dart';

/// Open the [ScheduleFocusModal] in create mode, pre-filled with [date] and
/// [defaultPriority]. Backs the agenda date-header `+` button. Routing the
/// modal open through a [Command] gives it analytics tracking (via
/// [BuildContextCommandExtension.run]) and the standard [Button] hover
/// treatment instead of a bare `FButton`.
class OpenScheduleFocusModal extends Command {
  OpenScheduleFocusModal({required this.date, this.defaultPriority})
    : super(
        title: 'Schedule focus block',
        icon: PlotIcon.plus,
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
      );

  final Date date;
  final Priority? defaultPriority;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await Modal(
      showCloseButton: false,
      builder: (_) =>
          ScheduleFocusModal.create(date: date, defaultPriority: defaultPriority),
    ).show<void>(context);
    return const CommandDone();
  }
}

/// Create or update a user-scheduled "focus block" — a `priority_block`
/// row carrying explicit `effective_at` (block start time) and `duration`.
/// Rendered in the agenda by [_insertExplicitFocusBlocks].
///
/// If [existingRow] is null, creates a fresh row at ([priorityId], [start]).
/// If [existingRow] is non-null:
///   - When [start] or [priorityId] changed: soft-archive the existing
///     row and write a new one for the new slot.
///   - When only [duration] changed: upsert in place.
class ScheduleFocusBlock extends Command {
  ScheduleFocusBlock({
    required this.priorityId,
    required this.start,
    required this.duration,
    this.existingRow,
  }) : super(
         title: existingRow == null
             ? 'Schedule focus block'
             : 'Update focus block',
         icon: PlotIcon.priority,
         eventObject: EventObject.priority,
         eventAction: existingRow == null
             ? EventAction.scheduled
             : EventAction.updated,
       );

  final PriorityId priorityId;
  final DateTime start;
  final Duration duration;
  final PriorityBlockRow? existingRow;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (duration <= Duration.zero) {
      return const CommandMessage(
        'Duration must be greater than zero.',
        isError: true,
      );
    }

    final existing = existingRow;
    final movedSlot = existing != null &&
        (existing.priorityId != priorityId ||
            !existing.effectiveAt.isAtSameMomentAs(start));

    if (existing != null && movedSlot) {
      // Soft-archive the existing row so it stops rendering at its
      // previous slot before we write the new one.
      final archived = existing.copyWith(
        archivedAt: Value(DateTime.now()),
        updatedAt: DateTime.now(),
      );
      await Store.get.save(
        store.PriorityBlock.table,
        archived.toCompanion(false),
        PriorityBlocksBase(),
      );
    }

    await store.PriorityBlock.setBlockDuration(
      priorityId: priorityId,
      blockStart: start,
      newDuration: duration,
    );

    return const CommandDone();
  }
}

/// Soft-archive a focus block row. Used by the edit modal's Delete action.
class ArchiveFocusBlock extends Command {
  ArchiveFocusBlock({required this.row})
    : super(
        title: 'Delete focus block',
        icon: PlotIcon.remove,
        eventObject: EventObject.priority,
        eventAction: EventAction.archived,
      );

  final PriorityBlockRow row;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    if (row.archivedAt != null) return const CommandDone();
    final archived = row.copyWith(
      archivedAt: Value(DateTime.now()),
      updatedAt: DateTime.now(),
    );
    await Store.get.save(
      store.PriorityBlock.table,
      archived.toCompanion(false),
      PriorityBlocksBase(),
    );
    return const CommandDone();
  }
}
