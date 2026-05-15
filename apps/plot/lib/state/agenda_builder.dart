import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/agenda_sort.dart';
import 'package:plot/state/priority.dart';
// Hide store.dart's `PriorityBlock` (the order-timeline class) so the
// `PriorityBlock` symbol below resolves to agenda_model.dart's UI block.
// The store-side timeline rows are referenced via [PriorityBlockRow]
// instead, which doesn't conflict.
import 'package:plot/store/store.dart' hide PriorityBlock;

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
  }) {
    if (threads.isEmpty) return AgendaModel.empty;

    final atoms = PriorityState.makeAgendaItems(
      threads,
      context: context,
      horizonDays: horizonDays,
      minFillDays: minFillDays,
      associationsByParentId: associationsByParentId,
    );

    final effectiveNow = now ?? DateTime.now();
    final base = _atomsToModel(atoms, context: context);
    final consolidated = _consolidateAndSort(
      base,
      now: effectiveNow,
      priorityBlocksByPriority: priorityBlocksByPriority ?? const {},
    );
    // Merge unread threads from the input that the day-by-`agendaAt`
    // grouping in [PriorityState.makeAgendaItems] dropped (e.g. an
    // unread thread last touched on a past date is filtered out by the
    // `!date.isBefore(today)` cutoff). Surface them on today's section
    // so the universal /agenda view never silently hides an unread
    // thread.
    final withUnread = _mergeUnreadIntoToday(
      consolidated,
      inputThreads: threads,
      now: effectiveNow,
    );
    // Populate each PriorityBlock's windowStart/windowEnd based on its
    // position relative to time-anchored siblings in the section.
    final withWindows = _populateBlockWindows(withUnread);
    // Attach per-block pending durations using the resolveBlockDurations
    // walker. Each priority's rows are resolved independently across all
    // sections; the result folds onto each block's cascadeDuration field.
    return _attachBlockDurations(
      withWindows,
      todayMidnight: _todayMidnightFromNow(effectiveNow),
      priorityBlocksByPriority: priorityBlocksByPriority ?? const {},
    );
  }

  /// Append every input thread with [Thread.unread] true that is not
  /// already part of any block in [model] into the today section,
  /// grouped by priority. If a [PriorityBlock] for that priority already
  /// exists on today, the unread thread is appended to it (after any
  /// scheduled threads, sorted by `updatedAt` descending). Otherwise a
  /// new [PriorityBlock] for that priority is created and appended at
  /// the end of today's section.
  ///
  /// EventBlock and GapBlock contributions are never replaced — only
  /// new [PriorityBlock]s get created. The today section is detected by
  /// `isNow == true` on the [DateSection]; if no such section exists in
  /// [model] (which can happen for an empty agenda before the today
  /// header has been synthesized), this is a no-op.
  static AgendaModel _mergeUnreadIntoToday(
    AgendaModel model, {
    required List<Thread> inputThreads,
    required DateTime now,
  }) {
    // Collect the thread ids that already appear anywhere in any block
    // in any section. We don't restrict to today because adding an
    // unread thread that already shows up on a future date (e.g. it has
    // an upcoming event-style schedule) would double-count it.
    final placedIds = <Uuid>{};
    for (final block in model.allBlocks) {
      for (final t in block.threads) {
        placedIds.add(t.id);
      }
    }

    // Find unread threads that haven't been placed.
    final unmergedUnread =
        inputThreads.where((t) => t.unread && !placedIds.contains(t.id)).toList();
    if (unmergedUnread.isEmpty) return model;

    // Group unmerged unread by priority, sorted within group by
    // updatedAt desc (newest unread on top).
    final byPriority = <Uuid, List<Thread>>{};
    final priorityOrder = <Uuid, Priority>{};
    for (final t in unmergedUnread) {
      byPriority.putIfAbsent(t.priority.id, () => <Thread>[]).add(t);
      priorityOrder.putIfAbsent(t.priority.id, () => t.priority);
    }
    for (final list in byPriority.values) {
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }

    // Locate the today section (the one flagged isNow == true). The
    // today header is always emitted by [PriorityState.makeAgendaItems]
    // (see the "Ensure today always has a date header" tail), so for
    // any non-empty agenda we will find one here.
    final newSections = <AgendaSection>[];
    var injected = false;
    for (final section in model.sections) {
      if (!injected && section is DateSection && section.isNow) {
        newSections.add(_appendUnreadToSection(
          section,
          unreadByPriority: byPriority,
          priorities: priorityOrder,
        ));
        injected = true;
      } else {
        newSections.add(section);
      }
    }

    // If we never found a today section (defensive — shouldn't happen
    // because makeAgendaItems always emits one), drop the unread merge
    // rather than fabricating a section here.
    if (!injected) return model;

    return AgendaModel(sections: List.unmodifiable(newSections));
  }

  static DateSection _appendUnreadToSection(
    DateSection section, {
    required Map<Uuid, List<Thread>> unreadByPriority,
    required Map<Uuid, Priority> priorities,
  }) {
    final newBlocks = <AgendaBlock>[...section.blocks];
    final remaining = Map<Uuid, List<Thread>>.from(unreadByPriority);

    // Append unread threads to existing PriorityBlocks first so a
    // priority that already owns a block on today doesn't gain a
    // duplicate.
    for (var i = 0; i < newBlocks.length; i++) {
      final block = newBlocks[i];
      if (block is! PriorityBlock) continue;
      final extras = remaining.remove(block.priority.id);
      if (extras == null || extras.isEmpty) continue;
      // Window is a placeholder; _populateBlockWindows rewrites it during build().
      newBlocks[i] = PriorityBlock(
        id: block.id,
        priority: block.priority,
        threads: List.unmodifiable([...block.threads, ...extras]),
        isOutside: false,
        windowStart: DateTime.fromMillisecondsSinceEpoch(0),
        windowEnd: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }

    // For priorities that have no PriorityBlock on today, append a new
    // PriorityBlock at the end of the section. We append (not insert
    // mid-section) so we don't disturb the gap-region ordering.
    final leftoverPriorityIds = remaining.keys.toList()
      // Stable order: the priority's compareTo (effective topOrder etc.).
      ..sort((a, b) => priorities[a]!.compareTo(priorities[b]!));
    for (final pid in leftoverPriorityIds) {
      final p = priorities[pid]!;
      final extras = remaining[pid]!;
      newBlocks.add(
        PriorityBlock(
          id: 'p_${section.id}_${p.path.value}_unread',
          priority: p,
          threads: List.unmodifiable(extras),
          isOutside: false,
          windowStart: DateTime.fromMillisecondsSinceEpoch(0),
          windowEnd: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    }

    return DateSection(
      date: section.date,
      blocks: List.unmodifiable(newBlocks),
      isNow: section.isNow,
      scheduleAt: section.scheduleAt,
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
      final newBlocks = _consolidateSection(
        section.blocks,
        sectionId: section.id,
        now: now,
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
    final referenceTime = gap.range.start ?? DateTime.now();

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
  /// and are passed through unchanged.
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
  })  : _kind = kind,
        _dateSeed = dateSeed,
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
