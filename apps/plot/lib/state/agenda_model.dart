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

  /// Flatten the model into the legacy [AgendaItem] atom shape consumed
  /// by callers that haven't migrated to direct block rendering yet.
  ///
  /// Output ordering:
  ///   - Sections in order; date/text section header atom first
  ///   - Within each section: blocks in order
  ///     - [GapBlock]: gap header atom, then thread atoms (truncated)
  ///     - [EventBlock]: event header atom, event row atom, then
  ///       associated child atoms (with `isAssociated: true`)
  ///     - [PriorityBlock]: header atom, then thread atoms (truncated)
  ///
  /// Truncation: priority-bearing blocks ([PriorityBlock] and
  /// [GapBlock]) emit at most [collapseLimit] threads by default. If a
  /// block has more, the last visible thread is marked
  /// `isCollapsedOverflow: true` so the renderer can fade it and turn
  /// taps into "expand this block". The block whose `id` matches
  /// [expandedBlockId] is exempt and emits all its threads in full.
  List<AgendaItem> flatItems({
    String? expandedBlockId,
    int collapseLimit = 2,
  }) {
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
            // Standalone priority-block header.
            out.add(
              AgendaHeaderItem(
                blockPriority: b.priority,
                isOutsidePriority: b.isOutside,
                parentBlockId: b.id,
                sourceDate: sectionDate,
                sourcePeriodStart: currentPeriodStart,
                parentBlockVisibleCount: _visibleCountFor(
                  b.threads.length,
                  isExpanded: expandedBlockId == b.id,
                  collapseLimit: collapseLimit,
                ),
              ),
            );
            _emitTruncated(
              out,
              threads: b.threads,
              isOutside: b.isOutside,
              blockId: b.id,
              expandedBlockId: expandedBlockId,
              collapseLimit: collapseLimit,
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
            // period.
            final hasThreads = b.threads.isNotEmpty;
            final gapStart = b.range.start;
            out.add(
              AgendaHeaderItem(
                dateTimeRange: b.range,
                blockPriority: hasThreads ? b.priority : null,
                isOutsidePriority: b.isOutside,
                parentBlockId: b.id,
                sourceDate: sectionDate,
                sourcePeriodStart: gapStart,
                parentBlockVisibleCount: _visibleCountFor(
                  b.threads.length,
                  isExpanded: expandedBlockId == b.id,
                  collapseLimit: collapseLimit,
                ),
              ),
            );
            _emitTruncated(
              out,
              threads: b.threads,
              isOutside: b.isOutside,
              blockId: b.id,
              expandedBlockId: expandedBlockId,
              collapseLimit: collapseLimit,
            );
            if (gapStart != null) {
              currentPeriodStart = gapStart;
            }
          case EventBlock b:
            // Combined event + priority header. Event blocks are not
            // draggable as a unit (the event row anchors them to a
            // time), but they still carry [parentBlockId] so the
            // renderer recognizes the block boundaries that flank them.
            // Draggability is gated by [thread == null] in the header
            // predicate, which excludes event headers.
            //
            // When the event is outside the current priority context,
            // the header carries its title (rendered on the priority's
            // tinted background) and we omit the event row itself — the
            // header alone is enough to locate it in the day.
            out.add(
              AgendaHeaderItem(
                dateTimeRange: b.event.at,
                thread: b.event,
                now: b.isCurrent,
                blockPriority: b.priority,
                isOutsidePriority: b.isOutside,
                parentBlockId: b.id,
                sourceDate: sectionDate,
                sourcePeriodStart: currentPeriodStart,
                parentBlockVisibleCount: _visibleCountFor(
                  1 + b.associated.length,
                  isExpanded: expandedBlockId == b.id,
                  collapseLimit: collapseLimit,
                ),
              ),
            );
            if (!b.isOutside) {
              out.add(
                AgendaThreadItem(
                  b.event,
                  now: b.isCurrent,
                  isOutsidePriority: b.isOutside,
                  parentBlockId: b.id,
                ),
              );
              final parentKey =
                  '${b.event.id}'
                  '${b.event.occurrence != null ? '_${b.event.occurrence}' : ''}';
              // Apply the same collapse rule as priority/gap blocks: when
              // the total visible row count (event + associated) exceeds
              // the limit and the block is not expanded, keep the event
              // row plus (collapseLimit - 1) associated rows, then emit a
              // carrier overflow row that the renderer turns into the
              // expand affordance.
              final isExpanded = expandedBlockId == b.id;
              final totalRows = 1 + b.associated.length;
              if (isExpanded || totalRows <= collapseLimit) {
                for (final child in b.associated) {
                  out.add(
                    AgendaThreadItem(
                      child,
                      isAssociated: true,
                      associationParentId: parentKey,
                      parentBlockId: b.id,
                    ),
                  );
                }
              } else {
                final visibleAssociated = collapseLimit - 1;
                for (var ci = 0; ci < visibleAssociated; ci++) {
                  out.add(
                    AgendaThreadItem(
                      b.associated[ci],
                      isAssociated: true,
                      associationParentId: parentKey,
                      parentBlockId: b.id,
                    ),
                  );
                }
                out.add(
                  AgendaThreadItem(
                    b.associated[visibleAssociated],
                    isAssociated: true,
                    associationParentId: parentKey,
                    parentBlockId: b.id,
                    isCollapsedOverflow: true,
                    collapsedBlockId: b.id,
                  ),
                );
              }
            }
        }
      }
    }
    return out;
  }

  /// Number of rows the renderer will produce for a block — the full
  /// thread count when expanded or below the limit, otherwise
  /// [collapseLimit] thread rows plus one trailing expand row.
  /// Used by [AgendaHeaderItem.parentBlockVisibleCount] to size the
  /// block-drag drop zones to the source block.
  static int _visibleCountFor(
    int totalThreads, {
    required bool isExpanded,
    required int collapseLimit,
  }) {
    if (isExpanded || totalThreads <= collapseLimit) return totalThreads;
    return collapseLimit + 1;
  }

  /// Emit threads with collapse rules applied. When the block has more
  /// than [collapseLimit] threads and is *not* the expanded block, emit
  /// [collapseLimit] real thread rows followed by an extra row carrying
  /// [AgendaThreadItem.isCollapsedOverflow] + the block id so the
  /// renderer can replace it with the expand affordance.
  static void _emitTruncated(
    List<AgendaItem> out, {
    required List<Thread> threads,
    required bool isOutside,
    required String blockId,
    required String? expandedBlockId,
    required int collapseLimit,
  }) {
    final isExpanded = expandedBlockId == blockId;
    if (isExpanded || threads.length <= collapseLimit) {
      for (final t in threads) {
        out.add(AgendaThreadItem(
          t,
          isOutsidePriority: isOutside,
          parentBlockId: blockId,
        ));
      }
      return;
    }
    for (var i = 0; i < collapseLimit; i++) {
      out.add(AgendaThreadItem(
        threads[i],
        isOutsidePriority: isOutside,
        parentBlockId: blockId,
      ));
    }
    // Carrier thread for the expand row — the renderer ignores [thread]
    // when [isCollapsedOverflow] is true and renders a chevron instead.
    // Use the first hidden thread so its stableKey is well-defined.
    out.add(
      AgendaThreadItem(
        threads[collapseLimit],
        isOutsidePriority: isOutside,
        isCollapsedOverflow: true,
        collapsedBlockId: blockId,
        parentBlockId: blockId,
      ),
    );
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
}

/// Threads belonging to a single [Priority], rendered under a priority
/// breadcrumb header.
class PriorityBlock extends AgendaBlock {
  const PriorityBlock({
    required this.id,
    required this.priority,
    required this.threads,
    this.isOutside = false,
  });

  @override
  final String id;
  @override
  final Priority priority;
  @override
  final List<Thread> threads;
  @override
  final bool isOutside;
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

  @override
  List<Object?> get props => [id, priority, range, threads, isOutside];
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
        a.isCollapsedOverflow
            ? 'expand_${a.collapsedBlockId}'
            : 'activity_${a.thread.id}${a.thread.occurrence != null ? '_${a.thread.occurrence}' : ''}${a.thread.isLinkScheduleInstance ? '_link' : ''}${a.isAssociated ? '_assoc${a.associationParentId != null ? '_${a.associationParentId}' : ''}' : ''}',
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
    this.isCollapsedOverflow = false,
    this.collapsedBlockId,
    this.parentBlockId,
  });

  final Thread thread;
  final bool now;
  final bool isNext;
  final bool isAssociated;

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

  /// True when this thread is the last visible item of an over-limit
  /// block (`block.threads.length > collapseLimit` and the block is not
  /// expanded). Renderers fade the row and intercept taps to call
  /// `PriorityBloc.toggleBlockExpansion(collapsedBlockId)` instead of
  /// opening the thread.
  final bool isCollapsedOverflow;

  /// When [isCollapsedOverflow] is true, the id of the block this row
  /// belongs to (so the tap handler knows which block to expand).
  final String? collapsedBlockId;

  /// The id of the [AgendaBlock] this thread belongs to (when known).
  /// Used by the renderer to collapse threads of a block whose header
  /// is being dragged. Null for event-block contents (events are not
  /// draggable as a unit) and for items not produced by [flatItems].
  final String? parentBlockId;

  @override
  List<Object?> get props => [
    thread,
    now,
    isNext,
    isAssociated,
    isOutsidePriority,
    associationParentId,
    isCollapsedOverflow,
    collapsedBlockId,
    parentBlockId,
  ];

  @override
  String toString() =>
      'AgendaThreadItem(thread: ${thread.title}, now: $now, isAssociated: $isAssociated, isOutsidePriority: $isOutsidePriority, isCollapsedOverflow: $isCollapsedOverflow, parentBlockId: $parentBlockId)';
}
