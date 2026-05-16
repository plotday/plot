import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'loading.dart';

/// The `/` route. Decides where the user actually lands based on layout
/// and the current priority:
///
///   - Single-panel: forwards to `/agenda` (the universal agenda page).
///   - Multi-panel: forwards to `/p/{NowLoaded.priority}` — the priority
///     at the top of the agenda. The agenda is already rendered in the
///     left sidebar by [LeftPanelAgendaView] in this layout, so the
///     middle panel shows the current priority's threads instead of
///     duplicating the agenda.
///
/// Listens to [LayoutBloc] (so resize transitions retrigger the redirect)
/// and [NowBloc] (so the chosen priority follows the canonical "current
/// priority" definition that includes active session, currently-running
/// scheduled events, and priority-block ordering).
@RoutePage()
class RootPage extends StatelessWidget {
  const RootPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
      builder: (context, layoutState) {
        if (!layoutState.multiPanel) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            context.router.replaceAll([const AgendaRoute()]);
          });
          return const LoadingPage();
        }
        return BlocBuilder<NowBloc, NowState>(
          builder: (context, nowState) {
            if (nowState is! NowLoaded) return const LoadingPage();
            final top = nowState.priority;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              // BlocBuilder already gated on multiPanel == true above, so
              // always land with NewThreadRoute in the right panel.
              context.router.replaceAll([
                PriorityRoute(
                  priorityIdString: top.id.toShortString(),
                  children: [NewThreadRoute()],
                ),
              ]);
            });
            return const LoadingPage();
          },
        );
      },
    );
  }
}
