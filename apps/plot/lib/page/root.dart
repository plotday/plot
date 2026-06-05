import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/now.dart';
import 'package:plot/store/store.dart';
import 'loading.dart';

/// The `/` route. Decides where the user actually lands based on layout
/// and the current priority:
///
///   - Single-panel: forwards to `/agenda` (the universal agenda page) when
///     a calendar connection exists, otherwise `/priorities` (Focuses) — the
///     agenda is hidden for users with no active calendar connection.
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
          return StreamBuilder<bool>(
            stream: TwistInstance.watchHasCalendarConnection(),
            initialData: TwistInstance.hasCalendarConnectionInCache,
            builder: (context, snap) {
              // Wait for a real stream emission before choosing the landing.
              // [initialData] (the cache) can be a stale `false` on cold
              // start; acting on it would land a calendar user on Focuses
              // instead of the agenda — and, paired with AgendaPage's
              // no-calendar redirect back to `/`, bounce forever.
              if (snap.connectionState != ConnectionState.active) {
                return const LoadingPage();
              }
              final hasCalendar = snap.data ?? false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                // Skip if we've already navigated past the root path. Without
                // this, a queued post-frame from a stale emit can fire after
                // the user has moved on, replaceAll-ing the stack and wiping
                // out their open thread.
                if (context.router.currentPath != '/') return;
                // No calendar connection → the agenda is hidden, so land on
                // Focuses instead of the (now-redirecting) agenda. This is
                // what breaks the /→/agenda→/ loop and matches the bottom
                // nav's homeIndex choice.
                context.router.replaceAll([
                  hasCalendar
                      ? const AgendaRoute()
                      : const PrioritiesRoute(),
                ]);
              });
              return const LoadingPage();
            },
          );
        }
        return BlocBuilder<NowBloc, NowState>(
          builder: (context, nowState) {
            if (nowState is! NowLoaded) return const LoadingPage();
            final top = nowState.priority;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              // Skip if we've already navigated past the root path. Multiple
              // NowBloc emissions during cold-start queue multiple post-frame
              // replaceAlls; the first lands us on /p/<id>/new and any later
              // ones would re-resolve the inner stack to [NewThreadRoute],
              // popping a ThreadRoute the user just opened. `context.mounted`
              // alone isn't enough — Element teardown lags one frame behind
              // the router state change.
              if (context.router.currentPath != '/') return;
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
