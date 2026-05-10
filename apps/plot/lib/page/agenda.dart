import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
/// vertical stack of [AgendaHeader]s.
@RoutePage()
class AgendaPage extends StatelessWidget {
  const AgendaPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, nowState) {
        if (nowState is! NowLoaded) {
          return const LoadingPage();
        }
        return PriorityBlocProvider(
          priority: nowState.defaultPriority,
          child: const _AgendaBody(),
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

/// Renders the agenda body as a vertical list of block headers.
///
/// Post-Task-8 the agenda is exclusively one [AgendaHeaderItem] per block —
/// no [AgendaThreadItem]s — so this widget only needs a simple stack of
/// [AgendaHeader] widgets. Drag-drop, infinite scroll, focus management,
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
        return AgendaHeader(
          key: ValueKey('agendaheader_${item.stableKey}'),
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
