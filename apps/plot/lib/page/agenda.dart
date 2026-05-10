import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/agenda.dart';
import 'package:plot/widget/scaffold.dart';
import 'loading.dart';

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
        final items = state.agendaViewItems;
        return Scaffold(
          scrollable: false,
          translucent: true,
          childPad: false,
          body: AgendaList(items: items),
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
          return const SizedBox.shrink();
        }
        return PriorityBlocProvider(
          priority: nowState.defaultPriority,
          // See note in [AgendaPage]: this is the universal agenda, not a
          // user-chosen context.
          setContext: false,
          child: BlocBuilder<PriorityBloc, PriorityState>(
            builder: (context, state) {
              if (!state.agendaLoaded) {
                return const SizedBox.shrink();
              }
              return AgendaList(items: state.agendaViewItems);
            },
          ),
        );
      },
    );
  }
}

/// Renders the agenda body as a vertical list of block headers.
///
/// Post-Task-8 the agenda is exclusively one [AgendaHeaderItem] per block —
/// no [AgendaThreadItem]s — so this widget only needs a simple stack of
/// [AgendaTile] widgets. Drag-drop, infinite scroll, focus management,
/// and the activity-feed branch all live in [PriorityPage] and are not
/// applicable here.
class AgendaList extends StatelessWidget {
  const AgendaList({required this.items, super.key});

  final List<AgendaItem> items;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item is! AgendaHeaderItem) {
          // The universal agenda only emits header items; skip anything
          // unexpected (e.g. a stray thread item slipped through) rather
          // than crash. Returning an empty box keeps indices aligned.
          return const SizedBox.shrink();
        }
        return AgendaTile(
          key: ValueKey('agendatile_${item.stableKey}'),
          dateTimeRange: item.dateTimeRange,
          date: item.date,
          now: item.now,
          isNext: item.isNext,
          thread: item.thread,
          text: item.text,
          scheduleAt: item.scheduleAt,
          block: item.block,
          parentBlockId: item.parentBlockId,
          sourceDate: item.sourceDate,
          sourcePeriodStart: item.sourcePeriodStart,
          parentBlockVisibleCount: item.parentBlockVisibleCount,
        );
      },
    );
  }
}
