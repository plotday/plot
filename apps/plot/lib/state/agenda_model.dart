import 'package:equatable/equatable.dart';
import 'package:plot/store/store.dart';

/// The agenda's canonical view: an ordered list of sections, each
/// containing an ordered list of blocks, each containing threads.
class AgendaModel extends Equatable {
  const AgendaModel({required this.sections});

  final List<AgendaSection> sections;

  static const empty = AgendaModel(sections: []);

  Iterable<AgendaBlock> get allBlocks =>
      sections.expand((s) => s.blocks);

  Iterable<Thread> get allThreads =>
      allBlocks.expand((b) => b.threads);

  AgendaBlock? blockById(String id) {
    for (final s in sections) {
      for (final b in s.blocks) {
        if (b.id == id) return b;
      }
    }
    return null;
  }

  /// Flattens this model into a render-friendly list. Each block emits
  /// exactly one [AgendaHeaderItem]; per-thread items are not produced
  /// for the agenda view (the new agenda renders the block as a unit
  /// from the header's referenced [AgendaBlock] data).
  ///
  /// Output ordering:
  ///   - Sections in order; date/text section header item first
  ///   - Within each section: one header item per block in order
  List<AgendaItem> flatItems() {
    final out = <AgendaItem>[];
    for (final section in sections) {
      // Track the section's date and the most recent gap anchor so
      // each block header can carry its source-period metadata for the
      // block-drag system.
      final Date? sectionDate = switch (section) {
        DateSection s => s.date,
        TextSection _ => null,
      };
      DateTime? currentPeriodStart;
      switch (section) {
        case DateSection s:
          out.add(
            AgendaHeaderItem(
              date: s.date,
              now: s.isNow,
              scheduleAt: s.scheduleAt,
            ),
          );
        case TextSection s:
          if (s.text.isNotEmpty) {
            out.add(AgendaHeaderItem(text: s.text));
          }
      }
      for (final block in section.blocks) {
        switch (block) {
          case PriorityBlock b:
            out.add(
              AgendaHeaderItem(
                blockPriority: b.priority,
                block: b,
                isOutsidePriority: b.isOutside,
                parentBlockId: b.id,
                sourceDate: sectionDate,
                sourcePeriodStart: currentPeriodStart,
              ),
            );
          case GapBlock b:
            // Empty gaps are pure visual time markers — no priority,
            // neutral background. Gaps with threads carry the
            // priority of their first thread (combined gap+priority
            // header). Both carry [parentBlockId] so the renderer
            // recognizes the block transition for drop-zone insertion;
            // draggability is gated by [blockPriority != null] separately.
            // The gap defines a new period: this block — and any
            // blocks that follow it within the section — live in this
            // period. A residual gap (cascade leftover) inherits its
            // parent gap's anchor via [periodAnchor].
            final hasThreads = b.threads.isNotEmpty;
            final gapAnchor = b.periodAnchor ?? b.range.start;
            out.add(
              AgendaHeaderItem(
                dateTimeRange: b.range,
                blockPriority: hasThreads ? b.priority : null,
                block: hasThreads ? b : null,
                isOutsidePriority: b.isOutside,
                parentBlockId: b.id,
                sourceDate: sectionDate,
                sourcePeriodStart: gapAnchor,
              ),
            );
            if (gapAnchor != null) {
              currentPeriodStart = gapAnchor;
            }
          case EventBlock b:
            // Combined event + priority header. Event blocks are not
            // draggable as a unit (the event row anchors them to a
            // time), but they still carry [parentBlockId] so the
            // renderer recognizes the block boundaries that flank them.
            out.add(
              AgendaHeaderItem(
                dateTimeRange: b.event.at,
                thread: b.event,
                now: b.isCurrent,
                blockPriority: b.priority,
                block: b,
                isOutsidePriority: b.isOutside,
                parentBlockId: b.id,
                sourceDate: sectionDate,
                sourcePeriodStart: currentPeriodStart,
              ),
            );
        }
      }
    }
    return out;
  }

  @override
  List<Object?> get props => [sections];
}

/// One contiguous section of the agenda. Sections are top-level dividers
/// (a date, a text label like "From the server"). Each section contains
/// an ordered list of [AgendaBlock]s.
sealed class AgendaSection extends Equatable {
  const AgendaSection();

  String get id;
  List<AgendaBlock> get blocks;

  @override
  List<Object?> get props => [id, blocks];
}

/// Section anchored to a date. `isNow == true` flags the synthetic
/// "Today" section that today's `_makeAgenda` inserts before any
/// future day when today has no other content.
class DateSection extends AgendaSection {
  const DateSection({
    required this.date,
    required this.blocks,
    this.isNow = false,
    this.scheduleAt,
  });

  final Date date;
  @override
  final List<AgendaBlock> blocks;
  final bool isNow;
  final DateTime? scheduleAt;

  @override
  String get id => 'date_${date.toString()}';

  @override
  List<Object?> get props => [date, blocks, isNow, scheduleAt];
}

/// Section with a non-date label (e.g. "From the server").
class TextSection extends AgendaSection {
  const TextSection({required this.text, required this.blocks});

  final String text;
  @override
  final List<AgendaBlock> blocks;

  @override
  String get id => 'text_${text.toLowerCase().replaceAll(' ', '_')}';

  @override
  List<Object?> get props => [text, blocks];
}

/// A group of [Thread]s rendered as a unit. The block kind determines
/// the header style (priority breadcrumb, gap time, or event time) and
/// the drag semantics (in upcoming features).
sealed class AgendaBlock extends Equatable {
  const AgendaBlock();

  String get id;
  Priority get priority;
  List<Thread> get threads;
  bool get isOutside;

  @override
  List<Object?> get props => [id, priority, threads, isOutside];

  /// Joined `displayTitle` of threads in this block with non-empty
  /// titles, separated by ` · `. Empty when no titled threads exist.
  String get summaryLine => threads
      .map((t) => t.displayTitle)
      .where((s) => s.isNotEmpty)
      .join(' · ');
}

/// Threads belonging to a single [Priority], rendered under a priority
/// breadcrumb header.
class PriorityBlock extends AgendaBlock {
  const PriorityBlock({
    required this.id,
    required this.priority,
    required this.threads,
    this.isOutside = false,
    this.cascadeDuration,
  });

  @override
  final String id;
  @override
  final Priority priority;
  @override
  final List<Thread> threads;
  @override
  final bool isOutside;

  /// The priority's total pending duration folded into this block by the
  /// cascade pass. Null for blocks outside today's section, or for
  /// priorities with no pending duration.
  final Duration? cascadeDuration;

  @override
  List<Object?> get props => [id, priority, threads, isOutside, cascadeDuration];
}

/// A scheduled event thread together with any associated child threads,
/// rendered under a combined event-time + priority header.
class EventBlock extends AgendaBlock {
  const EventBlock({
    required this.id,
    required this.priority,
    required this.event,
    required this.associated,
    this.isCurrent = false,
    this.isOutside = false,
  });

  @override
  final String id;
  @override
  final Priority priority;
  final Thread event;
  final List<Thread> associated;
  final bool isCurrent;
  @override
  final bool isOutside;

  @override
  List<Thread> get threads => [event, ...associated];

  @override
  List<Object?> get props =>
      [id, priority, event, associated, isCurrent, isOutside];
}

/// A time gap between scheduled events, optionally containing threads
/// pinned to that interval. [threads] may be empty when the block exists
/// purely as a visual time marker.
class GapBlock extends AgendaBlock {
  const GapBlock({
    required this.id,
    required this.priority,
    required this.range,
    required this.threads,
    this.isOutside = false,
    this.periodAnchor,
  });

  @override
  final String id;
  @override
  final Priority priority;
  final DateTimeRange range;
  @override
  final List<Thread> threads;
  @override
  final bool isOutside;

  /// Overrides the period start used for drop-target attribution and
  /// the post-block `currentPeriodStart` walker state. Set on a residual
  /// gap (the leftover band emitted after cascade slices fill part of a
  /// gap) so it inherits the ORIGINAL gap's period anchor — drops into
  /// the residual then write priority_block rows at the gap's true
  /// start, where the cascade walker resolves them, instead of at the
  /// residual's own start (which the cascade never evaluates).
  /// Null for "normal" gaps where `range.start` is the canonical anchor.
  final DateTime? periodAnchor;

  @override
  List<Object?> get props =>
      [id, priority, range, threads, isOutside, periodAnchor];
}

/// Atom type used by the legacy flat-list rendering and reorder paths.
/// Lives here (rather than in `priority_state.dart`) so [AgendaModel]
/// can produce them via [AgendaModel.flatItems] without forming an
/// import cycle with `priority.dart`.
sealed class AgendaItem extends Equatable {
  const AgendaItem();

  T when<T>({
    required T Function(AgendaHeaderItem) header,
    required T Function(AgendaThreadItem) activity,
  }) {
    return switch (this) {
      AgendaHeaderItem h => header(h),
      AgendaThreadItem a => activity(a),
    };
  }

  /// Stable identity key for this item, used for scroll anchor correction
  /// and widget keys.
  String get stableKey => when(
    header: (h) => h.date != null
        ? 'header_date_${h.date}'
        : h.dateTimeRange != null
        ? 'header_event_${h.dateTimeRange}_${h.parentBlockId ?? h.blockPriority?.path.value ?? ""}'
        : h.parentBlockId != null
        ? 'header_block_${h.parentBlockId}'
        : h.blockPriority != null
        ? 'header_priority_${h.blockPriority!.path.value}'
        : 'header_other',
    activity: (a) =>
        'activity_${a.thread.id}${a.thread.occurrence != null ? '_${a.thread.occurrence}' : ''}${a.thread.isLinkScheduleInstance ? '_link' : ''}${a.isAssociated ? '_assoc${a.associationParentId != null ? '_${a.associationParentId}' : ''}' : ''}',
  );
}

class AgendaHeaderItem extends AgendaItem {
  const AgendaHeaderItem({
    this.dateTimeRange,
    this.date,
    this.now = false,
    this.isNext = false,
    this.thread,
    this.text,
    this.scheduleAt,
    this.isOutsidePriority = false,
    this.blockPriority,
    this.block,
    this.parentBlockId,
    this.sourceDate,
    this.sourcePeriodStart,
    this.parentBlockVisibleCount,
  });

  final DateTimeRange? dateTimeRange;
  final Date? date;
  final bool now;
  final bool isNext;
  final Thread? thread;
  final String? text;
  final DateTime? scheduleAt;

  /// Whether this header is for an event outside the current priority context.
  /// Outside-priority event headers are dimmed in the UI.
  final bool isOutsidePriority;

  /// When set, this header introduces a block of threads sharing this
  /// priority. Combined with [dateTimeRange] it carries gap- or
  /// event-block metadata; on its own it is a standalone priority-block
  /// header. The renderer draws an accent + veryMuted border pair when
  /// this is set.
  final Priority? blockPriority;

  /// The full [AgendaBlock] this header introduces. Set whenever
  /// [blockPriority] is set, so the renderer can derive the joined
  /// summary line, unread state, and other block-level metadata
  /// without re-reading the agenda model.
  final AgendaBlock? block;

  /// The id of the [AgendaBlock] this header introduces. Set for every
  /// block header ([PriorityBlock], [GapBlock], [EventBlock]) so the
  /// renderer can track block transitions for drop-zone insertion.
  /// Draggability as a block source is a separate predicate
  /// (`blockPriority != null && thread == null && !isOutsidePriority`).
  final String? parentBlockId;

  /// The [Date] this block lives in (null for orphan/text sections).
  /// Used by the block-drag system to compute the source period.
  final Date? sourceDate;

  /// The gap-anchor of the period this block lives in. For a GapBlock
  /// header, this is the gap's own start (the gap defines its period);
  /// for blocks that follow a gap within a section, this is the
  /// preceding gap's start; null for blocks above any gap on the date.
  final DateTime? sourcePeriodStart;

  /// How many thread rows the renderer will emit for this block —
  /// the full thread count when expanded / below the collapse limit,
  /// otherwise the limit. The block-drag drop zones use this (paired
  /// with the header's intrinsic height) to size themselves to the
  /// dragged block, so dropping into a zone "fits" the source.
  final int? parentBlockVisibleCount;

  @override
  List<Object?> get props => [
    dateTimeRange,
    date,
    now,
    isNext,
    thread,
    text,
    scheduleAt,
    isOutsidePriority,
    blockPriority,
    block,
    parentBlockId,
    sourceDate,
    sourcePeriodStart,
    parentBlockVisibleCount,
  ];

  @override
  String toString() =>
      'AgendaHeaderItem(dateTimeRange: $dateTimeRange, date: $date, now: $now, isNext: $isNext, text: $text, scheduleAt: $scheduleAt, blockPriority: ${blockPriority?.title}, parentBlockId: $parentBlockId, sourceDate: $sourceDate, sourcePeriodStart: $sourcePeriodStart, parentBlockVisibleCount: $parentBlockVisibleCount)';
}

class AgendaThreadItem extends AgendaItem {
  const AgendaThreadItem(
    this.thread, {
    this.now = false,
    this.isNext = false,
    this.isAssociated = false,
    this.isOutsidePriority = false,
    this.associationParentId,
    this.associationOrder,
    this.parentBlockId,
    this.hidden = false,
    this.pinned = false,
  });

  final Thread thread;
  final bool now;
  final bool isNext;
  final bool isAssociated;

  /// True when this row is pinned in place and cannot be reordered or
  /// dragged out of its section. Used for the event-thread row that
  /// leads the "Event Agenda" section.
  final bool pinned;

  /// Whether this thread is outside the current priority context.
  /// Outside-priority link-scheduled events are dimmed in the UI.
  final bool isOutsidePriority;

  /// Disambiguator for the same child thread appearing under multiple
  /// parent events (e.g. recurring event instances). Used in widget keys
  /// to prevent GlobalKey collisions.
  final String? associationParentId;

  /// The shared association order, used for reordering among associated
  /// threads. Null for non-associated items.
  final Order? associationOrder;

  /// The id of the [AgendaBlock] this thread belongs to (when known).
  /// Used by the renderer to collapse threads of a block whose header
  /// is being dragged. Null for event-block contents (events are not
  /// draggable as a unit) and for items not produced by [flatItems].
  final String? parentBlockId;

  /// True when this thread belongs to a collapsed block. The renderer
  /// keeps the row mounted but animates it down to zero height so
  /// expand/collapse transitions stay smooth across context changes.
  final bool hidden;

  @override
  List<Object?> get props => [
    thread,
    now,
    isNext,
    isAssociated,
    isOutsidePriority,
    associationParentId,
    parentBlockId,
    hidden,
    pinned,
  ];

  @override
  String toString() =>
      'AgendaThreadItem(thread: ${thread.title}, now: $now, isAssociated: $isAssociated, isOutsidePriority: $isOutsidePriority, parentBlockId: $parentBlockId, hidden: $hidden, pinned: $pinned)';
}
