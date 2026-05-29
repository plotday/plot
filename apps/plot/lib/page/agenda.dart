import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';

import 'package:plot/router.dart';
import 'package:plot/state/agenda_model.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
// Hide store.dart's `PriorityBlock` (the order-timeline class) to avoid
// shadowing agenda_model.dart's UI block re-exported via priority.dart.
// We still need to call its static `setBlockDuration` helper, which
// lives on the store-side class, so bring it in under an alias.
import 'package:plot/store/store.dart' hide PriorityBlock;
import 'package:plot/store/store.dart' as store show PriorityBlock;
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/block_list_separator.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'loading.dart';

final _log = Logger('AgendaPage');

/// The universal agenda page.
///
/// Mounted at `/agenda` (wired up by Task 10). Reuses [PriorityBloc] keyed
/// to the user's [NowLoaded.defaultPriority] — the same priority the old
/// root-redirect chose — and renders the agenda body without
/// [PriorityPage]'s activity-feed branch or per-priority tabs.
///
/// After Task 4 made [PriorityBloc]'s agenda universal, the bloc keyed to
/// the default priority produces blocks across every priority the user has
/// visibility into. Task 8 reduced each block to a single [AgendaHeaderItem]
/// (the per-thread rows are gone), so this page only needs to render a
/// vertical stack of [AgendaTile]s.
@RoutePage()
class AgendaPage extends StatelessWidget {
  const AgendaPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
      builder: (context, layoutState) {
        // In multi-panel mode the agenda is already rendered in the left
        // sidebar via [LeftPanelAgendaView], so navigating to /agenda is
        // redundant. Bounce back through the `/` route, which picks the
        // current priority from [NowLoaded.priority] and forwards there.
        if (layoutState.multiPanel) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            context.router.replaceAll([const RootRoute()]);
          });
          return const LoadingPage();
        }
        return BlocBuilder<NowBloc, NowState>(
          builder: (context, nowState) {
            if (nowState is! NowLoaded) {
              return const LoadingPage();
            }
            return PriorityBlocProvider(
              priority: nowState.defaultPriority,
              // Universal agenda — keyed to default priority for data, but
              // doesn't represent a user-chosen context. Don't overwrite
              // [NowBloc.context], or the bottom-nav Activity/New buttons
              // would always navigate to the default priority instead of
              // the priority the user was last viewing.
              setContext: false,
              child: const _AgendaBody(),
            );
          },
        );
      },
    );
  }
}

class _AgendaBody extends StatelessWidget {
  const _AgendaBody();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        if (!state.agendaLoaded) {
          return const LoadingPage();
        }
        // The agenda has no header on single-panel mobile, so the list
        // would slide under the status bar / dynamic island without an
        // explicit top SafeArea. The bottom nav (rendered at the shell
        // level) handles the bottom inset, so leave it off here.
        //
        // The first date row has no separator above it (separators sit
        // *between* items). On desktop the panel squircle paints that
        // top edge for us; on mobile we add an explicit 1px divider so
        // the first row reads as the top of a list rather than bleeding
        // into the status-bar background. (DecoratedBox + Border.top is
        // not enough — the list's opaque rows paint over a background
        // decoration, hiding the line.)
        return Scaffold(
          scrollable: false,
          translucent: true,
          childPad: false,
          body: SafeArea(
            top: true,
            bottom: false,
            left: false,
            right: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(height: 1, color: context.theme.colors.border),
                Expanded(child: AgendaList(items: state.agendaViewItems)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Renders the universal agenda body without a [Scaffold] wrapper, suitable
/// for embedding in another panel (e.g. the multi-panel layout's left
/// column). Provides its own [PriorityBlocProvider] keyed to the user's
/// default priority so the agenda is universal regardless of which
/// priority the surrounding page is showing.
class LeftPanelAgendaView extends StatelessWidget {
  const LeftPanelAgendaView({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, nowState) {
        if (nowState is! NowLoaded) {
          return const _CenteredAgendaSpinner();
        }
        return PriorityBlocProvider(
          priority: nowState.defaultPriority,
          // See note in [AgendaPage]: this is the universal agenda, not a
          // user-chosen context.
          setContext: false,
          child: BlocBuilder<PriorityBloc, PriorityState>(
            builder: (context, state) {
              if (!state.agendaLoaded) {
                return const _CenteredAgendaSpinner();
              }
              return ScrollEdgeFade(
                background: context.colour.background,
                child: AgendaList(items: state.agendaViewItems),
              );
            },
          ),
        );
      },
    );
  }
}

/// Centered loading spinner for the left-panel agenda. Mirrors
/// [LoadingPage]'s delayed-spinner behaviour (200ms grace to avoid a flash
/// on quick transitions) but without a Scaffold wrapper so it composes
/// inside the multi-panel layout's left column.
class _CenteredAgendaSpinner extends StatefulWidget {
  const _CenteredAgendaSpinner();

  @override
  State<_CenteredAgendaSpinner> createState() => _CenteredAgendaSpinnerState();
}

class _CenteredAgendaSpinnerState extends State<_CenteredAgendaSpinner> {
  bool _showSpinner = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _showSpinner = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fill the agenda's background while loading. The panel's outlined
    // squircle (`_outlinedSquircle` in resizable_panel_layout.dart) draws
    // only a foreground hairline border and no background fill — it relies
    // on the agenda content to paint the background. The loaded agenda
    // paints [context.colour.background] (via [ScrollEdgeFade]); without a
    // matching fill here the loading state shows a bordered box with a
    // transparent interior, which reads as an empty outline on startup.
    return ColoredBox(
      color: context.colour.background,
      child: Center(
        child: _showSpinner ? const Spinner(size: 22) : const SizedBox.shrink(),
      ),
    );
  }
}

/// Empty-state body shown when the agenda has loaded but produced zero
/// items. Replaces [InfiniteList]'s default "loading" spinner so the
/// caller doesn't mistake a genuinely empty agenda for one that's still
/// fetching forever.
class _AgendaEmptyState extends StatelessWidget {
  const _AgendaEmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.contentPaddingH,
        vertical: context.theme.spacing.xl,
      ),
      child: Center(
        child: Text(
          'Nothing scheduled.\nCreate a thread or add a connection to fill your agenda.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.theme.plotColors.veryMuted,
            fontSize: context.theme.typography.sm.fontSize,
          ),
        ),
      ),
    );
  }
}

/// Renders the agenda body as a vertical list of block headers with
/// matching dividers and drag-to-reorder support.
///
/// Post-Task-8 the agenda is exclusively one [AgendaHeaderItem] per block —
/// no [AgendaThreadItem]s — so each row is the entire dragged block.
/// Drag/drop wiring mirrors [PriorityPage]'s activity feed (shared
/// [BlockDragController] + [BlockDropZone] + [BlockListSeparator])
/// so both lists behave identically; the dispatcher routes drops to
/// [PriorityBloc.reorderBlockWithinPeriod] (same period) or
/// [PriorityBloc.moveBlock] (cross period / cross date).
class AgendaList extends StatefulWidget {
  const AgendaList({required this.items, super.key});

  final List<AgendaItem> items;

  @override
  State<AgendaList> createState() => _AgendaListState();
}

class _AgendaListState extends State<AgendaList> with TickerProviderStateMixin {
  late final BlockDragController _dragController = BlockDragController(
    vsync: this,
  );
  late final InfiniteListController _listController = InfiniteListController();

  /// Memoized drop-boundary computation. Keyed by `items` reference —
  /// [PriorityState.agendaViewItems] returns a fresh list on every emit
  /// when the underlying agenda changes, so identity is the right key.
  List<AgendaItem>? _cachedBoundaryItems;
  ({
    Map<int, BlockDropTarget> before,
    Map<int, BlockDropTarget> after,
    BlockDropTarget? afterList,
  })?
  _cachedBoundaries;

  @override
  void dispose() {
    _dragController.dispose();
    _listController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    // The user's currently-viewed priority drives selection styling.
    // [PriorityPage] sets [NowBloc.context] when mounted, so this stays
    // accurate across navigation: arriving on /agenda after viewing a
    // priority keeps that priority highlighted; in multi-panel mode the
    // priority shown alongside is the highlighted one. Falls back to the
    // bloc's own context (= [NowLoaded.defaultPriority]) if NowBloc is
    // still loading — the agenda body only mounts after [NowLoaded]
    // upstream, so this branch is just defensive.
    final nowState = context.watch<NowBloc>().state;
    final currentPriorityId = nowState is NowLoaded
        ? nowState.priority.id
        : context.read<PriorityBloc>().state.context.id;
    // When an event is currently selected, restrict the "selected"
    // priority-tint to that one event so sibling events of the same
    // priority don't all light up.
    final currentEventId = nowState is NowLoaded
        ? nowState.currentEvent?.id
        : null;

    // Only the first matching block gets the priority-tinted highlight —
    // multiple siblings of the same priority would otherwise all light up
    // and dilute the "this is where you are" affordance.
    AgendaHeaderItem? firstSelectedItem;
    int? firstSelectedIndex;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! AgendaHeaderItem) continue;
      if (item.blockPriority?.id != currentPriorityId) continue;
      if (currentEventId != null && item.thread?.id != currentEventId) continue;
      firstSelectedItem = item;
      firstSelectedIndex = i;
      break;
    }

    final ({
      Map<int, BlockDropTarget> before,
      Map<int, BlockDropTarget> after,
      BlockDropTarget? afterList,
    })
    boundaries;
    if (identical(_cachedBoundaryItems, items) && _cachedBoundaries != null) {
      boundaries = _cachedBoundaries!;
    } else {
      boundaries = computeBlockDropBoundaries(items: items);
      _cachedBoundaryItems = items;
      _cachedBoundaries = boundaries;
    }

    // Re-wire the dispatcher / preview builder on every build so they
    // close over the current items list. Without this, an in-flight
    // drag started against an older items snapshot would dispatch to
    // boundaries that have since shifted.
    _dragController.dispatcher = (payload, target) {
      _dispatchBlockDrop(context, items, payload, target);
    };
    _dragController.previewBuilder = (payload) =>
        _buildBlockDragPreview(items, payload, currentPriorityId);

    final bloc = context.read<PriorityBloc>();
    // The parent only mounts [AgendaList] once `state.agendaLoaded` is
    // true. Reaching here with an empty list means the user genuinely
    // has no agenda items, not that data is still loading — show the
    // empty state widget instead of [InfiniteList]'s default fetch
    // spinner.
    final list = InfiniteList(
      controller: _listController,
      count: items.length,
      doneEnd: bloc.state.agendaDoneEnd,
      fetcher: (first, count) => bloc.fetchMoreAgendaItems(first, count),
      initialScrollOffset: bloc.agendaScrollOffset,
      emptyPlaceholder: const _AgendaEmptyState(),
      onScrollOffsetChanged: (offset) => bloc.agendaScrollOffset = offset,
      itemKey: (i) =>
          i >= 0 && i < items.length ? items[i].stableKey : 'empty_$i',
      separatorBuilder: (context, index) => BlockListSeparator(
        prev: index > 0 && index - 1 < items.length ? items[index - 1] : null,
        next: index < items.length ? items[index] : null,
        controller: _listController,
        dragController: _dragController,
        index: index,
        selectedAccent: (item) {
          if (!identical(item, firstSelectedItem)) return null;
          return context.colour.colours.fromTheme(
            firstSelectedItem!.blockPriority!.displayColor,
          );
        },
        // Block headers carry their own hover affordance (the drag grip
        // revealed on hover); divider hover/focus brightening would
        // double up on the affordance. Date/text headers and gap markers
        // don't have a hover meaning at all. So no item type opts in.
        canHighlight: (_) => false,
        // Each agenda block is a single row whose drag id is its
        // [parentBlockId]; nothing else in the list participates in
        // drag-source matching.
        dragSourceId: (item) =>
            item is AgendaHeaderItem ? item.parentBlockId : null,
      ),
      builder: (context, index, focusNode, {reorderableIndex}) {
        if (index < 0 || index >= items.length) return null;
        final current = items[index];
        if (current is! AgendaHeaderItem) {
          // The universal agenda only emits header items; skip anything
          // unexpected (e.g. a stray thread item slipped through) rather
          // than crash. Returning an empty box keeps indices aligned.
          return const SizedBox.shrink();
        }

        final beforeBoundary = boundaries.before[index];
        final afterBoundary =
            boundaries.after[index] ??
            (index == items.length - 1 ? boundaries.afterList : null);

        // Empty gap headers (no priority lead) render their
        // before-boundary BELOW the row instead of above. Blocks can only
        // land inside such a gap, so the drop preview should appear inside
        // the gap rather than between the preceding block and the gap
        // header.
        //
        // Gap headers that promoted a priority into their lead (threads or
        // cascade slice) behave like ordinary priority blocks — they sit in
        // the gap's period and the user can swap them with adjacent
        // priority blocks. Keep their drop slot ABOVE the tile so the
        // bracketing-pair activation logic has a slot at the block's top
        // edge; otherwise dragging up onto the priority-led gap's body
        // grabs the slot above the preceding block (wrong period) and the
        // reorder dispatch early-returns with "no bracketing blocks."
        final isEmptyGapHeader =
            current.dateTimeRange != null &&
            current.thread == null &&
            current.parentBlockId != null &&
            current.sourcePeriodStart != null &&
            current.blockPriority == null;

        final selected = index == firstSelectedIndex;

        return Column(
          mainAxisSize: MainAxisSize.min,
          key: ValueKey('agenda_${current.stableKey}'),
          children: [
            if (beforeBoundary != null && !isEmptyGapHeader)
              BlockDropZone(
                key: ValueKey('agenda_drop_before_${current.stableKey}'),
                slotKey: 'agenda_drop_before_${current.stableKey}',
                target: beforeBoundary,
                // Sits directly above the AgendaTile in this column —
                // [InfiniteList]'s separator paints the top divider; the
                // bottom edge needs its own so the placeholder gap reads
                // as a distinct slot from the row beneath.
                dividerBelow: true,
              ),
            AgendaTile(
              key: ValueKey('agendatile_${current.stableKey}'),
              dateTimeRange: current.dateTimeRange,
              date: current.date,
              now: current.now,
              isNext: current.isNext,
              thread: current.thread,
              focusNode: focusNode,
              text: current.text,
              scheduleAt: current.scheduleAt,
              block: current.block,
              parentBlockId: current.parentBlockId,
              sourceDate: current.sourceDate,
              sourcePeriodStart: current.sourcePeriodStart,
              parentBlockVisibleCount: current.parentBlockVisibleCount,
              selected: selected,
            ),
            if (beforeBoundary != null && isEmptyGapHeader)
              BlockDropZone(
                key: ValueKey('agenda_drop_in_gap_${current.stableKey}'),
                slotKey: 'agenda_drop_in_gap_${current.stableKey}',
                target: beforeBoundary,
                // Sits directly below the gap-header AgendaTile in this
                // column with no separator between them, so the top edge
                // needs its own divider. The next row's separator
                // (rendered by [InfiniteList] above the next index)
                // covers the bottom edge.
                dividerAbove: true,
              ),
            if (afterBoundary != null)
              BlockDropZone(
                key: ValueKey('agenda_drop_after_${current.stableKey}'),
                slotKey: 'agenda_drop_after_${current.stableKey}',
                target: afterBoundary,
                // Same reasoning as the in-gap zone: sits directly
                // below the row's content; the next row's separator (or
                // the list's bottom edge) covers below.
                dividerAbove: true,
              ),
          ],
        );
      },
    );

    return BlockDragScope(controller: _dragController, child: list);
  }

  /// Dispatch a block-drop event from the [BlockDragController].
  ///
  /// Source identity comes from [payload.blockId]; target slot is
  /// described by [target]. Same-period reorders go through
  /// [PriorityBloc.reorderBlockWithinPeriod] (writes a `priority_block`
  /// row). Cross-period or cross-date moves go through
  /// [PriorityBloc.moveBlock] (rewrites every contained thread's
  /// schedule). Drops adjacent to the source are filtered upstream by
  /// the controller's no-op slot logic, so we only see meaningful drops
  /// here.
  void _dispatchBlockDrop(
    BuildContext context,
    List<AgendaItem> listItems,
    BlockDragPayload payload,
    BlockDropTarget target,
  ) {
    AgendaHeaderItem? source;
    int? sourceIndex;
    for (var i = 0; i < listItems.length; i++) {
      final it = listItems[i];
      if (it is AgendaHeaderItem && it.parentBlockId == payload.blockId) {
        source = it;
        sourceIndex = i;
        break;
      }
    }
    final bloc = context.read<PriorityBloc>();
    final canonicalBlock = bloc.state.agenda.blockById(payload.blockId);
    if (source == null ||
        sourceIndex == null ||
        source.blockPriority == null ||
        canonicalBlock == null) {
      _log.info(
        '[agenda block-drop] dispatch skipped: source not found / no '
        'blockPriority (blockId=${payload.blockId} '
        'sourceFound=${source != null} '
        'blockPriorityNull=${source?.blockPriority == null} '
        'canonicalNull=${canonicalBlock == null})',
      );
      return;
    }
    final sourcePriority = source.blockPriority!;
    final sourceDate = source.sourceDate;
    final sourcePeriodStart = source.sourcePeriodStart;
    final sourceThreadIds = {for (final t in canonicalBlock.threads) t.id};

    // Focus blocks reschedule by moving their underlying `priority_block`
    // row, not by rewriting thread schedules. Each focus block is a
    // standalone [PriorityBlock] (id `fb_…`) carrying that row in
    // [PriorityBlock.sourceRow].
    final sourceRow =
        canonicalBlock is PriorityBlock ? canonicalBlock.sourceRow : null;
    if (sourceRow != null) {
      // Anchor the dropped focus block to the times of the blocks
      // flanking the drop slot: start when the block above ends, or —
      // when dropped before the day's first time-anchored block — its own
      // duration before that block. The activation algorithm filters
      // source-adjacent slots, so neither neighbor is ever the dragged
      // block. Read start/end null-safely (an [EventBlock]'s `start`/`end`
      // getters throw when its event has no `at`).
      DateTime? blockStart(AgendaBlock? b) => switch (b) {
        EventBlock e => e.event.at?.start,
        GapBlock g => g.range.start,
        PriorityBlock p => p.windowStart,
        null => null,
      };
      DateTime? blockEnd(AgendaBlock? b) => switch (b) {
        EventBlock e => e.event.at?.end,
        GapBlock g => g.range.end,
        PriorityBlock p => p.windowEnd,
        null => null,
      };
      final agenda = bloc.state.agenda;
      final prevBlock = target.prevBlockId == null
          ? null
          : agenda.blockById(target.prevBlockId!);
      final nextBlock = target.nextBlockId == null
          ? null
          : agenda.blockById(target.nextBlockId!);
      final resolved = resolveFocusBlockDropAnchor(
        prevStart: blockStart(prevBlock),
        prevEnd: blockEnd(prevBlock),
        nextStart: blockStart(nextBlock),
        prevIsGap: prevBlock is GapBlock,
        duration: sourceRow.duration,
      );

      // Fallback for drops with no time-anchored neighbor (e.g. onto an
      // empty date section): use the period/date anchor and let
      // [moveFocusBlock] preserve the source row's existing time-of-day.
      var focusAnchor = resolved.anchor;
      focusAnchor ??= target.targetPeriodStart;
      if (focusAnchor == null && target.targetDate != null) {
        focusAnchor = target.targetDate!.toDateTime();
      }
      if (focusAnchor == null) return;
      unawaited(
        bloc.moveFocusBlock(
          source: sourceRow,
          targetAnchor: focusAnchor,
          anchorIsExact: resolved.isExact,
        ),
      );
      return;
    }

    final sameDate = sourceDate == target.targetDate;
    final samePeriod = sourcePeriodStart == target.targetPeriodStart;
    _log.info(
      '[agenda block-drop] dispatch entry: priority=${sourcePriority.id} '
      'sourceDate=$sourceDate sourcePeriodStart=$sourcePeriodStart '
      'targetDate=${target.targetDate} '
      'targetPeriodStart=${target.targetPeriodStart} '
      'targetPrev=${target.prevBlockId} targetNext=${target.nextBlockId} '
      'sameDate=$sameDate samePeriod=$samePeriod '
      'threadIds=${sourceThreadIds.length}',
    );

    // Compute a sensible anchor for the target period — falls back to
    // the target date when the target sits above any gap, so a drop
    // lands at the top of that date instead of snapping back. Used by
    // both the cross-period move (thread-bearing sources) and the
    // reorder path's `periodReferenceTime` for cross-period cascade
    // drops below.
    // When the drop lacks a gap anchor, fall back to the target date's
    // midnight. The agenda render uses a per-section temporal lens
    // (see `AgendaBuilder._consolidateAndSort`) so a row anchored at
    // any moment within the target date will win for that date's
    // standalone run. Using `Time.now()` here was a bug: past-day
    // reorders ended up anchored to today, and same-day reorders kept
    // creating fresh rows at different moments-of-day.
    DateTime? targetAnchor = target.targetPeriodStart;
    if (targetAnchor == null && target.targetDate != null) {
      targetAnchor = target.targetDate!.toDateTime();
    }

    // If the drop lands inside a gap and the source priority has no
    // pending duration set, default it to `min(30m, gap.duration)` so
    // the priority occupies a sensible slice of the gap in the cascade.
    // Honors the existing pending when set ("use the block's duration"
    // path). Only fires for cross-period drops — a same-period reorder
    // doesn't change which gap the block lives in, so it can't be
    // interpreted as "dropping into" a new gap.
    if ((!sameDate || !samePeriod) && target.targetPeriodStart != null) {
      _ensurePendingForGapDrop(
        bloc,
        sourcePriority.id,
        target.targetPeriodStart!,
        target.targetDate,
      );
    }

    if ((!sameDate || !samePeriod) && sourceThreadIds.isNotEmpty) {
      // Cross-period move of a thread-bearing block — rewrite
      // contained-thread schedules to the target gap anchor.
      if (targetAnchor == null) {
        _log.info(
          '[agenda block-drop] cross-period drop with no anchor and no '
          'date — skipping (priority=${sourcePriority.id})',
        );
        return;
      }
      _log.info(
        '[agenda block-drop] cross-period move: priority=${sourcePriority.id} '
        'sourceGap=$sourcePeriodStart -> targetGap=$targetAnchor '
        '(targetPeriodStart=${target.targetPeriodStart}, '
        'targetDate=${target.targetDate})',
      );
      bloc.moveBlock(
        blockId: payload.blockId,
        threadIds: sourceThreadIds,
        targetGapAnchorAt: targetAnchor,
      );
      // Fall through to the reorder logic below: moveBlock relocates
      // the threads but doesn't establish priority-vs-priority ordering
      // on the target day, so the source priority would land at its
      // default order regardless of where in the target's list the
      // user dropped. The reorder logic below brackets the drop
      // position and writes a priority_block row at targetAnchor so
      // the priority lands where the user actually dropped it.
    }
    // Empty-thread sources (cascade slices representing a priority's
    // pending duration laid into a gap) fall through to the reorder
    // path. moveBlock can't act on them — it rewrites thread schedules
    // and a cascade slice has no threads — so routing here would no-op
    // and the drop would snap back. The reorder path uses target-side
    // bracketing only, so it handles both same-period and cross-period
    // cascade drops once `periodReferenceTime` is set to the target's
    // anchor below.

    // Same-period reorder — find bracketing priority-bearing blocks
    // within the target's period only. Standalone priority blocks
    // (thread == null) bracket the new ordering; events (thread != null)
    // are skipped because they're anchored to a fixed time and don't
    // participate in priority_block ordering. Headers whose period
    // anchor differs from the target's are skipped — without this, the
    // walk crosses period boundaries.
    final insertionIndex = _targetInsertionIndex(target, listItems);
    final targetPeriod = target.targetPeriodStart;
    bool inSamePeriod(AgendaHeaderItem h) =>
        h.sourcePeriodStart == targetPeriod;
    PriorityId? above;
    for (var i = insertionIndex - 1; i >= 0; i--) {
      final candidate = listItems[i];
      if (candidate is! AgendaHeaderItem) continue;
      if (candidate.date != null) break;
      if (candidate.parentBlockId == payload.blockId) continue;
      if (!inSamePeriod(candidate)) break;
      if (candidate.blockPriority != null && candidate.thread == null) {
        above = candidate.blockPriority!.id;
        break;
      }
    }
    PriorityId? below;
    for (var i = insertionIndex; i < listItems.length; i++) {
      final candidate = listItems[i];
      if (candidate is! AgendaHeaderItem) continue;
      if (candidate.date != null) break;
      if (candidate.parentBlockId == payload.blockId) continue;
      if (!inSamePeriod(candidate)) break;
      if (candidate.blockPriority != null && candidate.thread == null) {
        below = candidate.blockPriority!.id;
        break;
      }
    }

    if (above == sourcePriority.id || below == sourcePriority.id) {
      _log.info(
        '[agenda block-drop] same-period reorder skipped: bracketing '
        'priority matches source (priority=${sourcePriority.id} '
        'above=$above below=$below insertionIndex=$insertionIndex)',
      );
      return;
    }

    if (above == null && below == null) {
      // Nothing else lives in this period — there's no ordering to
      // express. Without this guard each rapid-fire drop in a single-
      // block period would write a fresh `priority_block` row.
      _log.info(
        '[agenda block-drop] same-period reorder skipped: no bracketing '
        'blocks (priority=${sourcePriority.id} '
        'insertionIndex=$insertionIndex listLen=${listItems.length})',
      );
      return;
    }

    final periodReferenceTime =
        targetAnchor ?? target.targetPeriodStart ?? Time.now();
    _log.info(
      '[agenda block-drop] same-period reorder: priority=${sourcePriority.id} '
      'above=${above ?? "-"} below=${below ?? "-"} '
      'period=$periodReferenceTime',
    );
    bloc.reorderBlockWithinPeriod(
      priorityId: sourcePriority.id,
      periodReferenceTime: periodReferenceTime,
      above: above,
      below: below,
    );
  }

  /// When a block lands in a gap and its priority has no pending
  /// duration, set it to `min(30m, remaining-gap-duration)`. The
  /// "remaining" gap is the residual band the cascade emitted after
  /// existing priorities filled part of the gap (if any), otherwise
  /// the full original gap. This makes the default react to what's
  /// already booked: dropping into a half-filled 1h gap defaults to
  /// the remaining 30 minutes rather than overflowing into the next
  /// period.
  void _ensurePendingForGapDrop(
    PriorityBloc bloc,
    PriorityId priorityId,
    DateTime targetPeriodStart,
    Date? targetDate,
  ) {
    // Look up whether a row already exists for this priority at the
    // target period's anchor. The agenda model already attached the
    // resolved duration; read it off the matching block.
    final agenda = bloc.state.agenda;
    Duration? current;
    for (final section in agenda.sections) {
      if (targetDate != null &&
          section is DateSection &&
          section.date != targetDate) {
        continue;
      }
      for (final block in section.blocks) {
        if (block.priority.id != priorityId) continue;
        if (block.start != targetPeriodStart) continue;
        if (block is PriorityBlock) current = block.cascadeDuration;
        if (block is GapBlock) current = block.cascadeDuration;
      }
    }
    if (current != null && current > Duration.zero) return;

    final available = _availableInGap(agenda, targetPeriodStart, targetDate);
    if (available == null || available <= Duration.zero) {
      _log.info(
        '[agenda block-drop] skip pending default: no gap room at '
        'periodStart=$targetPeriodStart date=$targetDate',
      );
      return;
    }
    const defaultBlock = Duration(minutes: 30);
    final newPending = available < defaultBlock ? available : defaultBlock;
    _log.info(
      '[agenda block-drop] defaulting pending duration: priority=$priorityId '
      'period=$targetPeriodStart available=$available -> $newPending',
    );
    unawaited(
      store.PriorityBlock.setBlockDuration(
        priorityId: priorityId,
        blockStart: targetPeriodStart,
        newDuration: newPending,
      ),
    );
  }

  /// Returns the available room in the gap anchored at [periodStart].
  /// Prefers the residual band (the leftover the cascade emitted after
  /// existing priorities consumed part of the gap) so the caller
  /// reasons over what's actually free; falls back to the full gap
  /// from `max(now, gap.start)` when no residual exists.
  Duration? _availableInGap(
    AgendaModel agenda,
    DateTime periodStart,
    Date? targetDate,
  ) {
    GapBlock? original;
    GapBlock? residual;
    for (final section in agenda.sections) {
      if (targetDate != null &&
          section is DateSection &&
          section.date != targetDate) {
        continue;
      }
      for (final block in section.blocks) {
        if (block is! GapBlock) continue;
        if (block.periodAnchor == periodStart) {
          residual ??= block;
        } else if (block.range.start == periodStart) {
          original ??= block;
        }
      }
    }
    final gap = residual ?? original;
    if (gap == null) return null;
    final start = gap.range.start;
    final end = gap.range.end;
    if (start == null || end == null) return null;
    final nowTs = Time.now();
    final effectiveStart = nowTs.isAfter(start) ? nowTs : start;
    if (!effectiveStart.isBefore(end)) return null;
    return end.difference(effectiveStart);
  }

  /// Resolve the listItems index where a [BlockDropTarget] sits.
  ///
  /// - If [target.nextBlockId] is non-null, the boundary is rendered
  ///   above the row whose [parentBlockId] matches it.
  /// - If [nextBlockId] is null and [prevBlockId] is non-null, the
  ///   boundary sits right after the prev block's last row.
  /// - Otherwise the boundary is at the end of the list.
  int _targetInsertionIndex(
    BlockDropTarget target,
    List<AgendaItem> listItems,
  ) {
    final next = target.nextBlockId;
    if (next != null) {
      for (var i = 0; i < listItems.length; i++) {
        final it = listItems[i];
        if (it is AgendaHeaderItem && it.parentBlockId == next) return i;
      }
    }
    final prev = target.prevBlockId;
    if (prev != null) {
      for (var i = 0; i < listItems.length; i++) {
        final it = listItems[i];
        if (it is AgendaHeaderItem && it.parentBlockId == prev) return i + 1;
      }
    }
    return listItems.length;
  }

  /// Static dimmed preview rendered inside the active [BlockDropZone].
  /// Built from the source block's row so the gap shows what will land
  /// there instead of empty space. Caller wraps in [Opacity] +
  /// [IgnorePointer]; we just produce the raw widgets.
  ///
  /// Returns `null` when the source block can't be located in [items]
  /// — the drop zone falls back to an empty gap.
  Widget? _buildBlockDragPreview(
    List<AgendaItem> items,
    BlockDragPayload payload,
    PriorityId? currentPriorityId,
  ) {
    for (final item in items) {
      if (item is! AgendaHeaderItem) continue;
      if (item.parentBlockId != payload.blockId) continue;
      // Render the tile WITHOUT [parentBlockId] so the preview header
      // isn't itself wired into the drag system. The selected styling
      // mirrors what the tile shows at rest in the list — keeps the
      // dragged shape visually consistent with the source.
      final selected = item.blockPriority?.id == currentPriorityId;
      return AgendaTile(
        dateTimeRange: item.dateTimeRange,
        date: item.date,
        now: item.now,
        isNext: item.isNext,
        thread: item.thread,
        text: item.text,
        scheduleAt: item.scheduleAt,
        block: item.block,
        selected: selected,
      );
    }
    return null;
  }
}
