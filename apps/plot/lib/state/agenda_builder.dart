import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/agenda_sort.dart';
import 'package:plot/state/priority.dart';
// Hide store.dart's `PriorityBlock` (the order-timeline class) so the
// `PriorityBlock` symbol below resolves to agenda_model.dart's UI block.
// The store-side timeline rows are referenced via [PriorityBlockRow]
// instead, which doesn't conflict.
import 'package:plot/store/store.dart' hide PriorityBlock;

DateTime _laterOf(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

/// Pure builder for the agenda's [AgendaModel].
///
/// During this transitional iteration [build] delegates to
/// [PriorityState.makeAgendaItems] for the canonical thread ordering and
/// then groups the resulting flat atoms into [AgendaSection]s and
/// [AgendaBlock]s. Visual ordering is therefore bit-identical to today.
/// Once the agenda is fully block-aware (a later iteration that adds
/// dynamic priority grouping), the atom step disappears and this becomes
/// a native block constructor.
class AgendaBuilder {
  static AgendaModel build({
    required List<Thread> threads,
    required Priority context,
    required int horizonDays,
    int minFillDays = 0,
    Map<Uuid, List<ThreadAssociationRow>>? associationsByParentId,
    DateTime? now,
    Map<PriorityId, List<PriorityBlockRow>>? priorityBlocksByPriority,
    /// Optional lookup used by [_insertExplicitFocusBlocks] so focus
    /// blocks for priorities with no threads in [threads] still render.
    /// Defaults to deriving from `threads`.
    Map<PriorityId, Priority>? priorityById,
  }) {
    if (threads.isEmpty && (priorityBlocksByPriority?.isEmpty ?? true)) {
      return AgendaModel.empty;
    }

    // Drop threads whose [Thread.agendaAt] was auto-forwarded to today —
    // active items with no explicit today schedule. The explicit-only
    // agenda surfaces those through the priority's Active list instead.
    final agendaThreads =
        threads.where((t) => !t.isAgendaAtAutoForwarded).toList();

    final atoms = PriorityState.makeAgendaItems(
      agendaThreads,
      context: context,
      horizonDays: horizonDays,
      minFillDays: minFillDays,
      associationsByParentId: associationsByParentId,
    );

    final effectiveNow = now ?? Time.now();
    final base = _atomsToModel(atoms, context: context);
    final consolidated = _consolidateAndSort(
      base,
      now: effectiveNow,
      priorityBlocksByPriority: priorityBlocksByPriority ?? const {},
    );
    // Build a default priorityById from the input threads if the caller
    // didn't supply one — a thread's `.priority` covers most cases for
    // the focus-block insertion below.
    final defaultPriorityById = priorityById ??
        {for (final t in threads) t.priority.id: t.priority};
    // Group the ORIGINAL (pre-filter) thread set by priority. Focus
    // blocks borrow these for the summary line — without it the user
    // sees an empty preview, since the explicit-only filter
    // (`isAgendaAtAutoForwarded`) keeps the priority's active todos out
    // of the agenda's atom stream.
    final threadsByPriority = <PriorityId, List<Thread>>{};
    for (final t in threads) {
      threadsByPriority.putIfAbsent(t.priority.id, () => []).add(t);
    }
    // Insert empty UI blocks for user-scheduled focus blocks (priority_block
    // rows with explicit `effective_at` time-of-day + duration). These
    // render at their explicit times rather than being sequenced from
    // neighbors.
    final withFocusBlocks = _insertExplicitFocusBlocks(
      consolidated,
      priorityBlocksByPriority: priorityBlocksByPriority ?? const {},
      priorityById: defaultPriorityById,
      threadsByPriority: threadsByPriority,
      now: effectiveNow,
    );
    // Populate each PriorityBlock's windowStart/windowEnd based on its
    // position relative to time-anchored siblings in the section. Blocks
    // that already carry an explicit non-epoch window (focus blocks) are
    // preserved.
    final withWindows = _populateBlockWindows(withFocusBlocks);
    // Attach per-block pending durations using the resolveBlockDurations
    // walker. Each priority's rows are resolved independently across all
    // sections; the result folds onto each block's cascadeDuration field.
    return _attachBlockDurations(
      withWindows,
      todayMidnight: _todayMidnightFromNow(effectiveNow),
      priorityBlocksByPriority: priorityBlocksByPriority ?? const {},
    );
  }

  /// Post-process [model] so that each "time period" (a gap region or the
  /// standalone region between events) contains at most one
  /// [PriorityBlock] per priority. Within each block threads are sorted
  /// per [AgendaSort.compareThreadsInBlock]. Blocks within a region are
  /// sorted by each priority's effective order at the region's reference
  /// time.
  ///
  /// Implements rule 1 (one block per priority per period) and rule 5
  /// (within-block sort with prepend-on-arrival) of the redesign.
  static AgendaModel _consolidateAndSort(
    AgendaModel model, {
    required DateTime now,
    required Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority,
  }) {
    final newSections = <AgendaSection>[];
    for (final section in model.sections) {
      // Per-section temporal lens for standalone priority-block ordering.
      // Each `DateSection`'s standalone run answers "what priority order
      // is in effect for this date?" — using the section date's end as
      // the floor lets a row anchored within that date win for that
      // date's render. For today, take the later of `now` and EOD so a
      // future-scheduled row within today is still visible while not
      // regressing the "right now" order. Past sections keep `now` so
      // today's reorders bleed forward into past renders the same way
      // they did before.
      final sectionNow = switch (section) {
        DateSection s => _laterOf(
            now,
            s.date.toEnd().subtract(const Duration(microseconds: 1)),
          ),
        TextSection _ => now,
      };
      final newBlocks = _consolidateSection(
        section.blocks,
        sectionId: section.id,
        now: sectionNow,
        priorityBlocksByPriority: priorityBlocksByPriority,
      );
      switch (section) {
        case DateSection s:
          newSections.add(
            DateSection(
              date: s.date,
              blocks: List.unmodifiable(newBlocks),
              isNow: s.isNow,
              scheduleAt: s.scheduleAt,
            ),
          );
        case TextSection s:
          newSections.add(
            TextSection(text: s.text, blocks: List.unmodifiable(newBlocks)),
          );
      }
    }
    return AgendaModel(sections: List.unmodifiable(newSections));
  }

  /// Process one section's blocks. We walk linearly and treat each
  /// region (a GapBlock + its trailing PriorityBlocks, or a run of
  /// standalone PriorityBlocks between events) as a unit. EventBlocks
  /// pass through unchanged — they are not "time periods" per the spec.
  static List<AgendaBlock> _consolidateSection(
    List<AgendaBlock> blocks, {
    required String sectionId,
    required DateTime now,
    required Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority,
  }) {
    final out = <AgendaBlock>[];
    final standaloneRun = <PriorityBlock>[];

    void flushStandalone() {
      if (standaloneRun.isEmpty) return;
      out.addAll(_consolidatePriorityBlocks(
        standaloneRun,
        referenceTime: now,
        sectionId: sectionId,
        priorityBlocksByPriority: priorityBlocksByPriority,
      ));
      standaloneRun.clear();
    }

    var i = 0;
    while (i < blocks.length) {
      final b = blocks[i];
      if (b is EventBlock) {
        flushStandalone();
        out.add(b);
        i++;
        continue;
      }
      if (b is GapBlock) {
        flushStandalone();
        // Collect any PriorityBlocks that immediately follow this gap as
        // part of the same gap region.
        final gapMembers = <PriorityBlock>[];
        var j = i + 1;
        while (j < blocks.length && blocks[j] is PriorityBlock) {
          gapMembers.add(blocks[j] as PriorityBlock);
          j++;
        }
        out.addAll(_consolidateGapRegion(
          gap: b,
          followingPriorityBlocks: gapMembers,
          sectionId: sectionId,
          priorityBlocksByPriority: priorityBlocksByPriority,
        ));
        i = j;
        continue;
      }
      if (b is PriorityBlock) {
        standaloneRun.add(b);
        i++;
        continue;
      }
      // Unreachable for the current sealed type set.
      out.add(b);
      i++;
    }
    flushStandalone();
    return out;
  }

  /// Consolidate a gap + its trailing priority blocks into a single gap
  /// region. The output is one [GapBlock] for the lowest-ordered priority
  /// (carrying the gap header) plus one [PriorityBlock] per other
  /// priority, ordered by effective priority order at the gap's start.
  static List<AgendaBlock> _consolidateGapRegion({
    required GapBlock gap,
    required List<PriorityBlock> followingPriorityBlocks,
    required String sectionId,
    required Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority,
  }) {
    // Reference time for this gap's block ordering = gap.range.start.
    final referenceTime = gap.range.start ?? Time.now();

    // Aggregate all threads by priority (gap.threads is the lead block).
    final byPriority = <Uuid, _PriorityAccum>{};
    void add(Priority p, Iterable<Thread> threads) {
      final accum = byPriority.putIfAbsent(
        p.id,
        () => _PriorityAccum(priority: p),
      );
      for (final t in threads) {
        accum.threads.add(t);
      }
    }

    if (gap.threads.isNotEmpty) {
      add(gap.priority, gap.threads);
    }
    for (final pb in followingPriorityBlocks) {
      add(pb.priority, pb.threads);
    }

    if (byPriority.isEmpty) {
      // Empty gap — preserve its header-only marker.
      return [gap];
    }

    // Sort each block's threads with the new rule, and rank priorities by
    // effective order at the reference time.
    final ranked = byPriority.values.toList()
      ..sort((a, b) {
        final aOrd = effectivePriorityOrderAt(
          moment: referenceTime,
          blocksForPriority: priorityBlocksByPriority[a.priority.id] ?? const [],
          fallback: a.priority.order.value,
        );
        final bOrd = effectivePriorityOrderAt(
          moment: referenceTime,
          blocksForPriority: priorityBlocksByPriority[b.priority.id] ?? const [],
          fallback: b.priority.order.value,
        );
        return aOrd.compareTo(bOrd);
      });

    for (final r in ranked) {
      r.threads.sort(
        (a, b) => AgendaSort.compareThreadsInBlock(a, b, referenceTime),
      );
    }

    // First priority wins the GapBlock header; the rest become
    // standalone PriorityBlocks within the section.
    final lead = ranked.first;
    final leadGap = GapBlock(
      id: gap.id,
      priority: lead.priority,
      range: gap.range,
      threads: List.unmodifiable(lead.threads),
      isOutside: false,
    );

    final out = <AgendaBlock>[leadGap];
    for (var k = 1; k < ranked.length; k++) {
      final r = ranked[k];
      // Window is a placeholder; _populateBlockWindows rewrites it during build().
      out.add(
        PriorityBlock(
          id: 'p_${sectionId}_${r.priority.path.value}'
              '_g${gap.range.start?.millisecondsSinceEpoch ?? 0}',
          priority: r.priority,
          threads: List.unmodifiable(r.threads),
          isOutside: false,
          windowStart: DateTime.fromMillisecondsSinceEpoch(0),
          windowEnd: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    }
    return out;
  }

  /// Consolidate a run of standalone PriorityBlocks (no gap header above
  /// them) into one block per priority, sorted by effective priority
  /// order at [referenceTime].
  static List<AgendaBlock> _consolidatePriorityBlocks(
    List<PriorityBlock> run, {
    required DateTime referenceTime,
    required String sectionId,
    required Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority,
  }) {
    if (run.isEmpty) return const [];

    final byPriority = <Uuid, _PriorityAccum>{};
    for (final pb in run) {
      final accum = byPriority.putIfAbsent(
        pb.priority.id,
        () => _PriorityAccum(priority: pb.priority),
      );
      accum.threads.addAll(pb.threads);
    }

    final ranked = byPriority.values.toList()
      ..sort((a, b) {
        final aOrd = effectivePriorityOrderAt(
          moment: referenceTime,
          blocksForPriority:
              priorityBlocksByPriority[a.priority.id] ?? const [],
          fallback: a.priority.order.value,
        );
        final bOrd = effectivePriorityOrderAt(
          moment: referenceTime,
          blocksForPriority:
              priorityBlocksByPriority[b.priority.id] ?? const [],
          fallback: b.priority.order.value,
        );
        return aOrd.compareTo(bOrd);
      });

    for (final r in ranked) {
      r.threads.sort(
        (a, b) => AgendaSort.compareThreadsInBlock(a, b, referenceTime),
      );
    }

    // Block ids include the priority's path but NOT the rank index so
    // the same priority keeps the same id when the user reorders. A
    // rank-suffixed id would change for every block in the section on
    // every drop, churning the agenda's widget keys (header rows,
    // BlockDropZone slot keys) — which breaks AnimatedContainer
    // continuity at the drop boundary and produces visible "snap"
    // artifacts after the drop completes.
    // Window is a placeholder; _populateBlockWindows rewrites it during build().
    return [
      for (final r in ranked)
        PriorityBlock(
          id: 'p_${sectionId}_${r.priority.path.value}',
          priority: r.priority,
          threads: List.unmodifiable(r.threads),
          isOutside: false,
          windowStart: DateTime.fromMillisecondsSinceEpoch(0),
          windowEnd: DateTime.fromMillisecondsSinceEpoch(0),
        ),
    ];
  }

  /// For every priority, walk its agenda blocks in chronological order
  /// (across all sections) and attach the duration that `priority_block`
  /// rows resolve to for each block. Replaces the previous
  /// `_cascadePendingDurations` fold, which surfaced a per-priority
  /// total on today only.
  static AgendaModel _attachBlockDurations(
    AgendaModel model, {
    required DateTime todayMidnight,
    required Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority,
  }) {
    if (priorityBlocksByPriority.isEmpty) return model;

    // 1. Build a chronological block list per priority.
    final blocksByPriority = <PriorityId, List<({String id, DateTime start})>>{};
    for (final section in model.sections) {
      for (final block in section.blocks) {
        // PriorityBlocks and priority-led GapBlocks are the only kinds
        // that carry a priority's pending; EventBlocks do not.
        if (block is PriorityBlock || block is GapBlock) {
          final list = blocksByPriority.putIfAbsent(
            block.priority.id,
            () => <({String id, DateTime start})>[],
          );
          list.add((id: block.id, start: block.start));
        }
      }
    }
    for (final list in blocksByPriority.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    // 2. Resolve durations per priority.
    final resolvedByBlockId = <String, Duration>{};
    for (final entry in blocksByPriority.entries) {
      final rows = priorityBlocksByPriority[entry.key] ?? const [];
      final perBlock = resolveBlockDurations(
        todayMidnight: todayMidnight,
        blocks: entry.value,
        blocksForPriority: rows,
      );
      for (final mapEntry in perBlock.entries) {
        final d = mapEntry.value;
        if (d != null) {
          resolvedByBlockId[mapEntry.key] = d;
        }
      }
    }

    if (resolvedByBlockId.isEmpty) return model;

    // 3. Fold the resolved durations back onto each block.
    final newSections = <AgendaSection>[];
    for (final section in model.sections) {
      final newBlocks = <AgendaBlock>[];
      for (final block in section.blocks) {
        final dur = resolvedByBlockId[block.id];
        if (dur == null) {
          newBlocks.add(block);
          continue;
        }
        if (block is PriorityBlock) {
          newBlocks.add(PriorityBlock(
            id: block.id,
            priority: block.priority,
            threads: block.threads,
            isOutside: block.isOutside,
            cascadeDuration: dur,
            windowStart: block.windowStart,
            windowEnd: block.windowEnd,
            overflow: block.overflow,
          ));
        } else if (block is GapBlock) {
          newBlocks.add(GapBlock(
            id: block.id,
            priority: block.priority,
            range: block.range,
            threads: block.threads,
            isOutside: block.isOutside,
            periodAnchor: block.periodAnchor,
            cascadeDuration: dur,
          ));
        } else {
          newBlocks.add(block);
        }
      }
      switch (section) {
        case DateSection s:
          newSections.add(DateSection(
            date: s.date,
            blocks: List.unmodifiable(newBlocks),
            isNow: s.isNow,
            scheduleAt: s.scheduleAt,
          ));
        case TextSection s:
          newSections.add(TextSection(
            text: s.text,
            blocks: List.unmodifiable(newBlocks),
          ));
      }
    }
    return AgendaModel(sections: List.unmodifiable(newSections));
  }

  /// Compute today's local midnight from [now]. Pulled out so tests
  /// can pass a frozen `now`.
  static DateTime _todayMidnightFromNow(DateTime now) =>
      DateTime(now.year, now.month, now.day);

  /// Returns `(start, end)` for a standalone [PriorityBlock] at index
  /// [blockIndex] inside [sectionBlocks], which all belong to
  /// [sectionDate]. Walks back to find the closest preceding time-anchored
  /// block (gap or event) and forward to find the next. The standalone's
  /// window is `[prevEnd ?? sectionMidnight, nextStart ?? sectionMidnight + 1d)`.
  static ({DateTime start, DateTime end}) _standaloneWindow({
    required Date sectionDate,
    required List<AgendaBlock> sectionBlocks,
    required int blockIndex,
  }) {
    final midnight = sectionDate.toDateTime();
    DateTime? prevEnd;
    for (var i = blockIndex - 1; i >= 0; i--) {
      final b = sectionBlocks[i];
      if (b is GapBlock) {
        prevEnd = b.range.end;
        if (prevEnd != null) break;
      } else if (b is EventBlock) {
        prevEnd = b.event.at?.end;
        if (prevEnd != null) break;
      }
    }
    DateTime? nextStart;
    for (var i = blockIndex + 1; i < sectionBlocks.length; i++) {
      final b = sectionBlocks[i];
      if (b is GapBlock) {
        nextStart = b.range.start;
        if (nextStart != null) break;
      } else if (b is EventBlock) {
        nextStart = b.event.at?.start;
        if (nextStart != null) break;
      }
    }
    return (
      start: prevEnd ?? midnight,
      end: nextStart ?? midnight.add(const Duration(days: 1)),
    );
  }

  /// Rebuild every [PriorityBlock] in every [DateSection] with the
  /// `start`/`end` window derived from its position in the section.
  /// `GapBlock` and `EventBlock` already carry their own time anchors
  /// and are passed through unchanged. Blocks that already carry a
  /// non-epoch window (user-scheduled focus blocks, see
  /// [_insertExplicitFocusBlocks]) keep their window.
  static AgendaModel _populateBlockWindows(AgendaModel model) {
    final newSections = <AgendaSection>[];
    for (final section in model.sections) {
      if (section is! DateSection) {
        newSections.add(section);
        continue;
      }
      final blocks = section.blocks;
      final rebuilt = <AgendaBlock>[];
      for (var i = 0; i < blocks.length; i++) {
        final b = blocks[i];
        if (b is PriorityBlock) {
          if (b.windowStart.millisecondsSinceEpoch > 0 &&
              b.windowEnd.millisecondsSinceEpoch > 0) {
            // Explicit focus block — keep its already-set window.
            rebuilt.add(b);
            continue;
          }
          final w = _standaloneWindow(
            sectionDate: section.date,
            sectionBlocks: blocks,
            blockIndex: i,
          );
          rebuilt.add(PriorityBlock(
            id: b.id,
            priority: b.priority,
            threads: b.threads,
            isOutside: b.isOutside,
            cascadeDuration: b.cascadeDuration,
            windowStart: w.start,
            windowEnd: w.end,
            overflow: b.overflow,
          ));
        } else {
          rebuilt.add(b);
        }
      }
      newSections.add(DateSection(
        date: section.date,
        blocks: List.unmodifiable(rebuilt),
        isNow: section.isNow,
        scheduleAt: section.scheduleAt,
      ));
    }
    return AgendaModel(sections: List.unmodifiable(newSections));
  }

  /// Insert one empty [PriorityBlock] per non-archived
  /// [PriorityBlockRow] whose `duration` is non-null and positive and
  /// whose `effectiveAt` falls on or after today. Each row renders as
  /// its own block at [windowStart] = `effectiveAt`,
  /// [windowEnd] = `effectiveAt + duration`. Blocks are placed in their
  /// matching [DateSection] (creating one if missing) in chronological
  /// order, threaded into the section between time-anchored neighbors
  /// (events, gaps) by start time.
  ///
  /// The block's [id] is `'fb_${row.id}'` so the drag/edit dispatch can
  /// recover the row id when the user reorders or edits.
  static AgendaModel _insertExplicitFocusBlocks(
    AgendaModel model, {
    required Map<PriorityId, List<PriorityBlockRow>> priorityBlocksByPriority,
    required Map<PriorityId, Priority> priorityById,
    required Map<PriorityId, List<Thread>> threadsByPriority,
    required DateTime now,
  }) {
    if (priorityBlocksByPriority.isEmpty) return model;

    final todayMidnight = _todayMidnightFromNow(now);

    // Collect focus blocks grouped by Date.
    final byDate = <Date, List<({PriorityBlockRow row, Priority priority})>>{};
    final priorityLookup = <PriorityId, Priority>{};
    // Build a fast Priority lookup from blocks already in the model, then
    // overlay the caller-supplied [priorityById] so focus-block priorities
    // with no other agenda presence can still resolve.
    for (final section in model.sections) {
      for (final block in section.blocks) {
        priorityLookup[block.priority.id] = block.priority;
      }
    }
    for (final entry in priorityById.entries) {
      priorityLookup.putIfAbsent(entry.key, () => entry.value);
    }
    // Collect block start times already in the model so we don't double-
    // render: a row whose effective_at matches the start of an existing
    // EventBlock, GapBlock, or PriorityBlock will attach its duration via
    // [_attachBlockDurations] downstream — we only insert a *new* UI block
    // for rows that don't line up with an existing anchor.
    final existingStarts = <int>{};
    for (final section in model.sections) {
      for (final block in section.blocks) {
        final s = block.start;
        if (s.millisecondsSinceEpoch > 0) {
          existingStarts.add(s.millisecondsSinceEpoch);
        }
      }
    }

    for (final entry in priorityBlocksByPriority.entries) {
      final priority = priorityLookup[entry.key];
      if (priority == null) continue;
      for (final row in entry.value) {
        if (row.archivedAt != null) continue;
        final d = row.duration;
        if (d == null || d <= Duration.zero) continue;
        if (row.effectiveAt.isBefore(todayMidnight)) continue;
        // Skip rows that line up with an existing block's start time —
        // those are legacy duration anchors attached to that block by
        // the resolver, not new user-scheduled focus blocks.
        if (existingStarts.contains(row.effectiveAt.millisecondsSinceEpoch)) {
          continue;
        }
        // Skip day-boundary anchors (midnight). Those are also carry-
        // forward rows the resolver attaches to today's chronological run.
        final at = row.effectiveAt;
        if (at.hour == 0 && at.minute == 0 && at.second == 0 &&
            at.millisecond == 0 && at.microsecond == 0) {
          continue;
        }
        final date = Date(at.year, at.month, at.day);
        byDate.putIfAbsent(date, () => []).add((row: row, priority: priority));
      }
    }

    if (byDate.isEmpty) return model;

    final remaining = Map<Date, List<({PriorityBlockRow row, Priority priority})>>.from(byDate);

    PriorityBlock buildFocusBlock(
      ({PriorityBlockRow row, Priority priority}) entry,
    ) {
      final start = entry.row.effectiveAt;
      final end = entry.row.effectiveAt.add(entry.row.duration!);
      // Preview the priority's top active threads so the user sees what
      // they parked for this focus slot. Sorted newest-first by
      // `agendaAt`, capped at 8 to keep the summary line readable.
      final priorityThreads = threadsByPriority[entry.priority.id] ?? const [];
      final activePreview = priorityThreads
          .where((t) => t.active && t.archivedAt == null)
          .toList()
        ..sort((a, b) => b.agendaAt.compareTo(a.agendaAt));
      final preview = activePreview.take(8).toList(growable: false);
      return PriorityBlock(
        id: 'fb_${entry.row.id}',
        priority: entry.priority,
        threads: List<Thread>.unmodifiable(preview),
        isOutside: false,
        cascadeDuration: entry.row.duration,
        windowStart: start,
        windowEnd: end,
        sourceRow: entry.row,
      );
    }

    int chronologicalIndex(AgendaBlock b) {
      // For ordering: events and gaps with a real start, plus focus
      // blocks carrying their own window. Thread-grouped PriorityBlocks
      // that still have epoch-zero windows sort to the end (after the
      // last time-anchored neighbor).
      if (b is EventBlock) {
        final s = b.event.at?.start;
        return s?.millisecondsSinceEpoch ?? 1 << 62;
      }
      if (b is GapBlock) {
        final s = b.range.start;
        return s?.millisecondsSinceEpoch ?? 1 << 62;
      }
      if (b is PriorityBlock) {
        if (b.windowStart.millisecondsSinceEpoch > 0) {
          return b.windowStart.millisecondsSinceEpoch;
        }
        return 1 << 62;
      }
      return 1 << 62;
    }

    final newSections = <AgendaSection>[];
    for (final section in model.sections) {
      if (section is! DateSection) {
        newSections.add(section);
        continue;
      }
      final extras = remaining.remove(section.date);
      if (extras == null || extras.isEmpty) {
        newSections.add(section);
        continue;
      }
      // Merge the section's existing blocks with the new focus blocks,
      // ordered by chronological start. Thread-grouped PriorityBlocks
      // with no explicit time fall in at the end of the section as
      // before.
      final merged = <AgendaBlock>[
        ...section.blocks,
        for (final e in extras) buildFocusBlock(e),
      ];
      merged.sort((a, b) => chronologicalIndex(a).compareTo(chronologicalIndex(b)));
      newSections.add(DateSection(
        date: section.date,
        blocks: List.unmodifiable(merged),
        isNow: section.isNow,
        scheduleAt: section.scheduleAt,
      ));
    }

    if (remaining.isEmpty) {
      return AgendaModel(sections: List.unmodifiable(newSections));
    }

    // Focus blocks whose date had no existing DateSection: synthesize
    // one, sorted in chronologically.
    final extraDates = remaining.keys.toList()..sort();
    for (final date in extraDates) {
      final extras = remaining[date]!;
      final blocks = [for (final e in extras) buildFocusBlock(e)]
        ..sort((a, b) => a.start.compareTo(b.start));
      final newSection = DateSection(
        date: date,
        blocks: List.unmodifiable(blocks),
        isNow: false,
      );
      var inserted = false;
      for (var i = 0; i < newSections.length; i++) {
        final s = newSections[i];
        if (s is DateSection && s.date.compareTo(date) > 0) {
          newSections.insert(i, newSection);
          inserted = true;
          break;
        }
      }
      if (!inserted) newSections.add(newSection);
    }
    return AgendaModel(sections: List.unmodifiable(newSections));
  }

  /// Group a flat [AgendaItem] list into sections and blocks.
  ///
  /// Section boundaries: date headers and text headers.
  /// Block boundaries within a section:
  ///   - Event header → [EventBlock] containing the event row plus any
  ///     immediately-following `isAssociated` thread items.
  ///   - Gap header → [GapBlock] containing the first contiguous
  ///     same-priority run of threads that follow it; subsequent
  ///     priority runs become [PriorityBlock]s within the same section.
  ///   - Standalone threads → [PriorityBlock]s grouping consecutive
  ///     threads of the same priority.
  static AgendaModel _atomsToModel(
    List<AgendaItem> atoms, {
    required Priority context,
  }) {
    final sections = <AgendaSection>[];
    _SectionBuilder? current;

    void flushSection() {
      if (current != null) {
        sections.add(current!.build());
        current = null;
      }
    }

    var i = 0;
    while (i < atoms.length) {
      final item = atoms[i];

      if (item is AgendaHeaderItem) {
        // Date header → start a new DateSection.
        if (item.date != null) {
          flushSection();
          current = _SectionBuilder.date(
            DateSection(
              date: item.date!,
              isNow: item.now,
              scheduleAt: item.scheduleAt,
              blocks: const [],
            ),
            context: context,
          );
          i++;
          continue;
        }

        // Pure text header (no date / no time range / no event thread)
        // → start a new TextSection.
        if (item.text != null &&
            item.dateTimeRange == null &&
            item.thread == null) {
          flushSection();
          current = _SectionBuilder.text(item.text!, context: context);
          i++;
          continue;
        }

        // Event header (has both a thread and a dateTimeRange).
        if (item.thread != null && item.dateTimeRange != null) {
          current ??= _SectionBuilder.orphan(context);
          current!.flushPriorityBlock();

          final event = item.thread!;
          // The next atom should be the event row itself; consume it.
          var j = i + 1;
          if (j < atoms.length) {
            final next = atoms[j];
            if (next is AgendaThreadItem && next.thread.id == event.id) {
              j++;
            }
          }
          // Then any immediately-following isAssociated items belong to
          // this event.
          final associated = <Thread>[];
          while (j < atoms.length) {
            final a = atoms[j];
            if (a is AgendaThreadItem && a.isAssociated) {
              associated.add(a.thread);
              j++;
            } else {
              break;
            }
          }

          current!.blocks.add(
            EventBlock(
              id: 'e_${current!.sectionId}_${event.id}'
                  '${event.occurrence != null ? '_${event.occurrence}' : ''}',
              priority: event.priority,
              event: event,
              associated: List.unmodifiable(associated),
              isCurrent: item.now,
              isOutside: false,
            ),
          );
          i = j;
          continue;
        }

        // Gap header (dateTimeRange only).
        if (item.dateTimeRange != null) {
          current ??= _SectionBuilder.orphan(context);
          current!.flushPriorityBlock();

          // Collect non-associated thread items that follow, until the
          // next header.
          final gapItems = <AgendaThreadItem>[];
          var j = i + 1;
          while (j < atoms.length) {
            final a = atoms[j];
            if (a is AgendaThreadItem && !a.isAssociated) {
              gapItems.add(a);
              j++;
            } else {
              break;
            }
          }

          final gapId = 'g_${current!.sectionId}_'
              '${item.dateTimeRange!.start?.millisecondsSinceEpoch ?? 0}';

          if (gapItems.isEmpty) {
            // Empty gap is a header-only marker. Use the next event's
            // priority if we can find one; otherwise fall back to context.
            Priority gapPriority = context;
            for (var k = j; k < atoms.length; k++) {
              final a = atoms[k];
              if (a is AgendaHeaderItem && a.thread != null) {
                gapPriority = a.thread!.priority;
                break;
              }
              if (a is AgendaThreadItem && !a.isAssociated) {
                gapPriority = a.thread.priority;
                break;
              }
            }
            current!.blocks.add(
              GapBlock(
                id: gapId,
                priority: gapPriority,
                range: item.dateTimeRange!,
                threads: const [],
                isOutside: false,
              ),
            );
          } else {
            // The first contiguous same-priority run goes into the
            // GapBlock so the gap header carries that priority's
            // breadcrumb. Subsequent priority runs become PriorityBlocks.
            var k = 0;
            final firstPriority = gapItems[k].thread.priority;
            while (k < gapItems.length &&
                gapItems[k].thread.priority == firstPriority) {
              k++;
            }
            current!.blocks.add(
              GapBlock(
                id: gapId,
                priority: firstPriority,
                range: item.dateTimeRange!,
                threads: List.unmodifiable(
                  gapItems.sublist(0, k).map((a) => a.thread),
                ),
                isOutside: false,
              ),
            );
            // Remaining gap items group by consecutive priority into
            // PriorityBlocks (under the same section, after the gap).
            while (k < gapItems.length) {
              final priority = gapItems[k].thread.priority;
              final start = k;
              while (k < gapItems.length &&
                  gapItems[k].thread.priority == priority) {
                k++;
              }
              final run = gapItems.sublist(start, k);
              // Window is a placeholder; _populateBlockWindows rewrites it during build().
              current!.blocks.add(
                PriorityBlock(
                  id: 'p_${current!.sectionId}_${priority.path.value}'
                      '_g${item.dateTimeRange!.start?.millisecondsSinceEpoch ?? 0}_$start',
                  priority: priority,
                  threads: List.unmodifiable(run.map((a) => a.thread)),
                  isOutside: false,
                  windowStart: DateTime.fromMillisecondsSinceEpoch(0),
                  windowEnd: DateTime.fromMillisecondsSinceEpoch(0),
                ),
              );
            }
          }
          i = j;
          continue;
        }

        // A header we don't recognize — skip.
        i++;
        continue;
      }

      if (item is AgendaThreadItem) {
        // Standalone thread — group into a PriorityBlock keyed on
        // consecutive same-priority runs.
        current ??= _SectionBuilder.orphan(context);
        current!.appendStandalone(item);
        i++;
        continue;
      }

      // Unreachable for the current sealed type set, but be defensive.
      i++;
    }

    flushSection();
    return AgendaModel(sections: List.unmodifiable(sections));
  }
}

/// Mutable accumulator for one section's blocks during atoms→blocks
/// conversion. Tracks an open [PriorityBlock] so consecutive standalone
/// threads of the same priority collapse into a single block.
class _SectionBuilder {
  _SectionBuilder._({
    required this.sectionId,
    required this.context,
    required _SectionKind kind,
    DateSection? dateSeed,
    String? text,
  })  :
        // ignore: prefer_initializing_formals
        _kind = kind,
        // ignore: prefer_initializing_formals
        _dateSeed = dateSeed,
        // ignore: prefer_initializing_formals
        _text = text;

  factory _SectionBuilder.date(
    DateSection seed, {
    required Priority context,
  }) {
    return _SectionBuilder._(
      sectionId: seed.id,
      context: context,
      kind: _SectionKind.date,
      dateSeed: seed,
    );
  }

  factory _SectionBuilder.text(
    String text, {
    required Priority context,
  }) {
    final id = 'text_${text.toLowerCase().replaceAll(' ', '_')}';
    return _SectionBuilder._(
      sectionId: id,
      context: context,
      kind: _SectionKind.text,
      text: text,
    );
  }

  /// A section that is collecting blocks but has no header atom yet —
  /// e.g. the empty agenda case before the first date appears, or
  /// content emitted before any header. Folds into a synthetic empty
  /// DateSection on build.
  factory _SectionBuilder.orphan(Priority context) {
    return _SectionBuilder._(
      sectionId: 'orphan',
      context: context,
      kind: _SectionKind.orphan,
    );
  }

  final String sectionId;
  final Priority context;
  final _SectionKind _kind;
  final DateSection? _dateSeed;
  final String? _text;

  final List<AgendaBlock> blocks = <AgendaBlock>[];

  /// Open priority-block accumulator: priority + threads collected so far.
  Priority? _openPriority;
  final List<Thread> _openThreads = <Thread>[];

  void appendStandalone(AgendaThreadItem item) {
    final t = item.thread;
    if (_openPriority == null) {
      _openPriority = t.priority;
      _openThreads.add(t);
      return;
    }
    if (_openPriority == t.priority) {
      _openThreads.add(t);
      return;
    }
    // Priority transition — flush and start a new run.
    flushPriorityBlock();
    _openPriority = t.priority;
    _openThreads.add(t);
  }

  void flushPriorityBlock() {
    if (_openPriority == null || _openThreads.isEmpty) return;
    // Window is a placeholder; _populateBlockWindows rewrites it during build().
    blocks.add(
      PriorityBlock(
        id: 'p_${sectionId}_${_openPriority!.path.value}_${blocks.length}',
        priority: _openPriority!,
        threads: List.unmodifiable(_openThreads),
        isOutside: false,
        windowStart: DateTime.fromMillisecondsSinceEpoch(0),
        windowEnd: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
    _openPriority = null;
    _openThreads.clear();
  }

  AgendaSection build() {
    flushPriorityBlock();
    final frozenBlocks = List<AgendaBlock>.unmodifiable(blocks);
    switch (_kind) {
      case _SectionKind.date:
        final seed = _dateSeed!;
        return DateSection(
          date: seed.date,
          blocks: frozenBlocks,
          isNow: seed.isNow,
          scheduleAt: seed.scheduleAt,
        );
      case _SectionKind.text:
        return TextSection(text: _text!, blocks: frozenBlocks);
      case _SectionKind.orphan:
        // No real header atom — synthesize an empty TextSection so the
        // blocks survive. In practice this only triggers for malformed
        // input from `_makeAgenda`; in the well-formed case every block
        // belongs to a date or text section.
        return TextSection(text: '', blocks: frozenBlocks);
    }
  }
}

enum _SectionKind { date, text, orphan }

class _PriorityAccum {
  _PriorityAccum({required this.priority});
  final Priority priority;
  final List<Thread> threads = <Thread>[];
}
