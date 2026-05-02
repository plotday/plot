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
    int collapseLimit = 3,
  }) {
    final out = <AgendaItem>[];
    for (final section in sections) {
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
            // header).
            out.add(
              AgendaHeaderItem(
                dateTimeRange: b.range,
                blockPriority: b.threads.isEmpty ? null : b.priority,
                isOutsidePriority: b.isOutside,
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
          case EventBlock b:
            // Combined event + priority header.
            out.add(
              AgendaHeaderItem(
                dateTimeRange: b.event.at,
                thread: b.event,
                now: b.isCurrent,
                blockPriority: b.priority,
                isOutsidePriority: b.isOutside,
              ),
            );
            out.add(
              AgendaThreadItem(
                b.event,
                now: b.isCurrent,
                isOutsidePriority: b.isOutside,
              ),
            );
            final parentKey =
                '${b.event.id}'
                '${b.event.occurrence != null ? '_${b.event.occurrence}' : ''}';
            for (final child in b.associated) {
              out.add(
                AgendaThreadItem(
                  child,
                  isAssociated: true,
                  associationParentId: parentKey,
                ),
              );
            }
        }
      }
    }
    return out;
  }

  /// Emit threads with collapse rules applied. When the block has more
  /// than [collapseLimit] threads and is *not* the expanded block, the
  /// last visible thread carries [AgendaThreadItem.isCollapsedOverflow]
  /// + the block id so the renderer can fade it and turn taps into a
  /// `toggleBlockExpansion(blockId)` call.
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
        out.add(AgendaThreadItem(t, isOutsidePriority: isOutside));
      }
      return;
    }
    final visibleCount = collapseLimit; // last one is the overflow marker
    for (var i = 0; i < visibleCount - 1; i++) {
      out.add(AgendaThreadItem(threads[i], isOutsidePriority: isOutside));
    }
    out.add(
      AgendaThreadItem(
        threads[visibleCount - 1],
        isOutsidePriority: isOutside,
        isCollapsedOverflow: true,
        collapsedBlockId: blockId,
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
        ? 'header_event_${h.dateTimeRange}_${h.blockPriority?.path.value ?? ""}'
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
  ];

  @override
  String toString() =>
      'AgendaHeaderItem(dateTimeRange: $dateTimeRange, date: $date, now: $now, isNext: $isNext, text: $text, scheduleAt: $scheduleAt, blockPriority: ${blockPriority?.title})';
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
  ];

  @override
  String toString() =>
      'AgendaThreadItem(thread: ${thread.title}, now: $now, isAssociated: $isAssociated, isOutsidePriority: $isOutsidePriority, isCollapsedOverflow: $isCollapsedOverflow)';
}
