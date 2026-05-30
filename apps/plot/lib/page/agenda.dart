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
import 'package:plot/store/store.dart' hide PriorityBlock;
import 'package:plot/widget/agenda_block_drag.dart';
import 'package:plot/widget/block_list_separator.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'loading.dart';

final _log = Logger('AgendaPage');

/// Index of the agenda block to highlight, or null when none should be.
///
/// Source priority:
///   1. [currentEventId] — an event the user tapped directly in the
///      agenda ([NowLoaded.currentEvent]).
///   2. [selectedBlockId] — a focus block or priority-led gap tapped
///      directly in the agenda ([NowLoaded.selectedBlockId]).
///   3. Otherwise the block covering [now], and only when it belongs to
///      [currentPriorityId]. So a priority change by a non-agenda route
///      (tree, header, thread) with no current-time block for that
///      priority highlights nothing.
///
/// Only the first match wins — multiple siblings of the same priority
/// would otherwise all light up and dilute the "this is where you are"
/// affordance.
int? agendaHighlightIndex({
  required List<AgendaItem> items,
  required PriorityId currentPriorityId,
  required Uuid? currentEventId,
  required String? selectedBlockId,
  required DateTime now,
}) {
  // True when [item]'s block covers [now]. Event blocks already carry the
  // answer in [AgendaHeaderItem.now] ([EventBlock.isCurrent]); focus
  // blocks and priority-led gaps are tested against their time window.
  bool coversNow(AgendaHeaderItem item) {
    if (item.now) return true;
    final start = item.dateTimeRange?.start;
    final end = item.dateTimeRange?.end;
    if (start == null || end == null) return false;
    return !now.isBefore(start) && now.isBefore(end);
  }

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! AgendaHeaderItem) continue;
    if (item.blockPriority == null) continue;
    final bool match;
    if (currentEventId != null) {
      match = item.thread?.id == currentEventId;
    } else if (selectedBlockId != null) {
      match = item.parentBlockId == selectedBlockId;
    } else {
      match = item.blockPriority?.id == currentPriorityId && coversNow(item);
    }
    if (match) return i;
  }
  return null;
}

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
/// matching dividers.
///
/// The agenda is exclusively one [AgendaHeaderItem] per block — events,
/// user-scheduled focus blocks, and read-only gap markers. Only focus
/// blocks are draggable: drag/drop wiring reuses the shared
/// [BlockDragController] + [BlockDropZone] + [BlockListSeparator] infra,
/// and the dispatcher routes the drop to [PriorityBloc.moveFocusBlock],
/// which reschedules the focus block's underlying `priority_block` row.
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
    // A directly-tapped event ([NowLoaded.currentEvent]) or focus block
    // ([NowLoaded.selectedBlockId]) is highlighted verbatim, wherever it
    // sits. With neither, we auto-highlight only the block covering the
    // current time — and only when its priority matches the viewed one.
    // So changing priority by a non-agenda route (tree, header, thread)
    // with no current-time block for that priority highlights nothing.
    final currentEventId = nowState is NowLoaded
        ? nowState.currentEvent?.id
        : null;
    final selectedBlockId = nowState is NowLoaded
        ? nowState.selectedBlockId
        : null;
    final now = nowState is NowLoaded ? nowState.now : Time.now();

    final selectedIndex = agendaHighlightIndex(
      items: items,
      currentPriorityId: currentPriorityId,
      currentEventId: currentEventId,
      selectedBlockId: selectedBlockId,
      now: now,
    );
    final selectedItem = selectedIndex != null
        ? items[selectedIndex] as AgendaHeaderItem
        : null;

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
          if (!identical(item, selectedItem)) return null;
          return context.colour.colours.fromTheme(
            selectedItem!.blockPriority!.displayColor,
          );
        },
        // Block headers carry their own hover affordance (the drag grip
        // revealed on hover); divider hover/focus brightening would
        // double up on the affordance. Date/text headers and gap markers
        // don't have a hover meaning at all. So no item type opts in.
        canHighlight: (_) => false,
        // Only user-scheduled focus blocks are draggable: events anchor to
        // a fixed time and gaps are read-only. A focus block's header
        // carries a [PriorityBlock] with a non-null [sourceRow].
        dragSourceId: (item) {
          if (item is! AgendaHeaderItem) return null;
          final block = item.block;
          return block is PriorityBlock && block.sourceRow != null
              ? item.parentBlockId
              : null;
        },
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

        final selected = index == selectedIndex;

        final inGapSlotKey = 'agenda_drop_in_gap_${current.stableKey}';

        Widget tile = AgendaTile(
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
        );

        // Dropping a block into an empty gap replaces the gap row rather
        // than inserting a new row. Collapse the gap's own row while the
        // drop lands in it, so the dragged block's preview grows into the
        // gap's position instead of opening a placeholder beneath an
        // unchanged gap row. This also keeps the drop from jumping: the
        // during-drag height already matches the post-drop layout (block
        // where the gap was). [BlockSlotCollapse] keys off the gap's block
        // id (not a single slot) so it merges consistently regardless of
        // which of the two coincident drop slots at the gap's lower edge
        // wins activation. See [BlockSlotCollapse].
        if (beforeBoundary != null &&
            isEmptyGapHeader &&
            current.parentBlockId != null) {
          tile = BlockSlotCollapse(
            blockId: current.parentBlockId!,
            child: tile,
          );
        }

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
            tile,
            if (beforeBoundary != null && isEmptyGapHeader)
              BlockDropZone(
                key: ValueKey('agenda_drop_in_gap_${current.stableKey}'),
                slotKey: inGapSlotKey,
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
  /// Source identity comes from [payload.blockId]. The only draggable
  /// block is a user-scheduled focus block, so the drop reschedules its
  /// `priority_block` row via [PriorityBloc.moveFocusBlock], anchoring to
  /// the time of the blocks flanking the drop slot. Drops adjacent to the
  /// source are filtered upstream by the controller's no-op slot logic, so
  /// we only see meaningful drops here.
  void _dispatchBlockDrop(
    BuildContext context,
    List<AgendaItem> listItems,
    BlockDragPayload payload,
    BlockDropTarget target,
  ) {
    AgendaHeaderItem? source;
    for (final it in listItems) {
      if (it is AgendaHeaderItem && it.parentBlockId == payload.blockId) {
        source = it;
        break;
      }
    }
    final bloc = context.read<PriorityBloc>();
    final canonicalBlock = bloc.state.agenda.blockById(payload.blockId);

    // In the explicit-only agenda the only draggable block is a
    // user-scheduled focus block — a [PriorityBlock] (id `fb_…`) carrying
    // its `priority_block` row in [PriorityBlock.sourceRow]. Events anchor
    // to a fixed time and gaps are read-only, so neither participates.
    // Focus blocks reschedule by moving that row, not by rewriting thread
    // schedules.
    final sourceRow =
        canonicalBlock is PriorityBlock ? canonicalBlock.sourceRow : null;
    if (source == null || sourceRow == null) {
      _log.info(
        '[agenda block-drop] skipped: not a focus block '
        '(blockId=${payload.blockId} sourceFound=${source != null} '
        'focusRow=${sourceRow != null})',
      );
      return;
    }

    // Anchor the dropped focus block to the times of the blocks flanking
    // the drop slot: start when the block above ends, or — when dropped
    // before the day's first time-anchored block — its own duration before
    // that block. The activation algorithm filters source-adjacent slots,
    // so neither neighbor is ever the dragged block. Read start/end
    // null-safely (an [EventBlock]'s `start`/`end` getters throw when its
    // event has no `at`).
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
