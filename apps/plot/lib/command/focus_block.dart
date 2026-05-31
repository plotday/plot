import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart' hide PriorityBlock;
import 'package:plot/store/store.dart' as store show PriorityBlock;
import 'package:plot/widget/form_scheduler.dart';
import 'package:plot/command/priority.dart' show createPriorityInline;
import 'package:plot/widget/widget.dart';

import 'base.dart';

/// Open the schedule-focus [FormModal] in create mode, pre-filled with [date]
/// and [defaultPriority] (see [openScheduleFocusModal]). Backs the agenda
/// date-header `+` button. Routing the modal open through a [Command] gives it
/// analytics tracking (via [BuildContextCommandExtension.run]) and the standard
/// [Button] hover treatment instead of a bare `FButton`.
class OpenScheduleFocusModal extends Command {
  OpenScheduleFocusModal({
    required this.date,
    this.defaultPriority,
    this.start,
    this.maxDuration,
  }) : super(
         title: 'Schedule focus block',
         icon: PlotIcon.add,
         eventObject: EventObject.priority,
         eventAction: EventAction.opened,
       );

  final Date date;
  final Priority? defaultPriority;

  /// Explicit start anchor for the new block (e.g. the agenda gap's start
  /// time). When null the form falls back to its [date]-based default.
  final DateTime? start;

  /// Upper bound on the block's default duration (e.g. the free time left
  /// in a gap). The default 30-minute block is shrunk to fit when this is
  /// smaller; null leaves the default untouched.
  final Duration? maxDuration;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await openScheduleFocusModal(
      context,
      date: date,
      initialPriority: defaultPriority,
      startTime: start,
      maxDuration: maxDuration,
    );
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
    final movedSlot =
        existing != null &&
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

/// Display-only command shown on the submit button while the form is still
/// incomplete (e.g. before a priority is picked), so the button reads
/// "Schedule focus block" / "Update focus block" instead of a generic label.
/// Never actually runs — submission is gated on form validation, which only
/// builds the real [ScheduleFocusBlock] once the required values are present.
class _ScheduleFocusBlockPlaceholder extends Command {
  _ScheduleFocusBlockPlaceholder({required bool isEdit})
    : super(
        title: isEdit ? 'Update focus block' : 'Schedule focus block',
        icon: PlotIcon.priority,
        eventObject: EventObject.priority,
        eventAction: EventAction.opened,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async =>
      const CommandSkipped();
}

/// Build the "Schedule focus block" form. Create mode when [existingRow] is
/// null; edit mode (with Delete + past-time editing) otherwise.
FormData scheduleFocusBlockForm({
  Date? date,
  Priority? initialPriority,
  PriorityBlockRow? existingRow,
  DateTime? startTime,
  Duration? maxDuration,
}) {
  final isEdit = existingRow != null;

  // Initial range: edit → from the row; create → [startTime] when given
  // (e.g. an agenda gap's start), else the next 15-min boundary today (or
  // 09:00 on a future date). 30-minute default, shrunk to [maxDuration]
  // when the available window is smaller.
  final DateTimeRange initialRange;
  if (isEdit) {
    final start = existingRow.effectiveAt;
    final duration = existingRow.duration ?? const Duration(minutes: 30);
    initialRange = DateTimeRange(start, start.add(duration));
  } else {
    final base = date?.toDateTime() ?? Date.today().toDateTime();
    final today = Date.today();
    final isToday =
        base.year == today.year &&
        base.month == today.month &&
        base.day == today.day;
    final DateTime start;
    if (startTime != null) {
      start = startTime;
    } else if (isToday) {
      final now = Time.now();
      final remainder = now.minute % 15;
      final pad = remainder == 0 ? 0 : 15 - remainder;
      start = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute + pad,
      );
    } else {
      start = DateTime(base.year, base.month, base.day, 9, 0);
    }
    const defaultDuration = Duration(minutes: 30);
    final duration =
        (maxDuration != null &&
            maxDuration > Duration.zero &&
            maxDuration < defaultDuration)
        ? maxDuration
        : defaultDuration;
    initialRange = DateTimeRange(start, start.add(duration));
  }

  final priorityField = FormSelect<Priority>(
    key: 'priority',
    label: 'Focus',
    required: true,
    placeholder: 'Select focus',
    initialValue: initialPriority,
    items: (search) async {
      final priorities = await Priority.get(order: PriorityOrder.nested);
      // Pin the root (Inbox) to the bottom as a branded row rather than
      // letting it appear inline as a plain focus.
      Priority? root;
      final focuses = <Priority>[];
      for (final p in priorities) {
        if (p.root) {
          root = p;
        } else if (search == null || search.isEmpty || p.matchesSearch(search)) {
          focuses.add(p);
        }
      }
      return [
        ...focuses,
        if (root != null &&
            (search == null || search.isEmpty || root.matchesSearch(search)))
          root,
      ];
    },
    titleBuilder: (p) => p.displayTitle,
    labelBuilder: (p) => FocusLabel(priority: p),
    onAdd: (ctx) => createPriorityInline(ctx, parent: initialPriority),
  );

  final scheduler = FormScheduler(
    key: 'schedule',
    initialRange: initialRange,
    allowPastTimes: isEdit,
  );

  final items = <FormItem>[
    priorityField,
    scheduler,
    FormButton(
      key: 'submit',
      isPrimary: true,
      buildCommand: (values) {
        final priority = values['priority'] as Priority?;
        final range = values['schedule'] as DateTimeRange?;
        final start = range?.start;
        final end = range?.end;
        // buildCommand is also called for display before the form is complete
        // (e.g. before a priority is picked). Show a labeled placeholder then;
        // submission is gated on validation so the real command only builds
        // once the required values are present.
        if (priority == null || start == null || end == null) {
          return _ScheduleFocusBlockPlaceholder(isEdit: isEdit);
        }
        return ScheduleFocusBlock(
          priorityId: priority.id,
          start: start,
          duration: end.difference(start),
          existingRow: existingRow,
        );
      },
    ),
    if (isEdit)
      FormButton(
        key: 'delete',
        skipValidation: true,
        buildCommand: (_) => ArchiveFocusBlock(row: existingRow),
      ),
  ];

  return FormData(
    title: isEdit ? 'Edit focus block' : 'Schedule focus block',
    dismissable: true,
    groups: [StaticFormGroup(items: items)],
  );
}

/// Open the schedule-focus modal as a [FormModal]. Used by both the agenda
/// date-header `+` button (create) and agenda block editing (create or edit).
Future<void> openScheduleFocusModal(
  BuildContext context, {
  Date? date,
  Priority? initialPriority,
  PriorityBlockRow? existingRow,
  DateTime? startTime,
  Duration? maxDuration,
}) async {
  final form = scheduleFocusBlockForm(
    date: date,
    initialPriority: initialPriority,
    existingRow: existingRow,
    startTime: startTime,
    maxDuration: maxDuration,
  );
  final groups = await form.list();
  if (!context.mounted) return;
  await FormModal(
    form,
    groups: groups,
    rootContext: context,
    constraints: const BoxConstraints(maxHeight: 520, maxWidth: 420),
  ).run(context);
}
