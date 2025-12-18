import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:flutter/foundation.dart';

import 'package:plot/command/command.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/state/user.dart';
import 'package:plot/widget/priorities_list.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/header.dart';
import 'package:plot/widget/list_tile.dart';
import 'package:plot/widget/icon.dart';

@RoutePage(name: 'PrioritiesRoute')
class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      scrollable: false,
      header: Header(
        title: defaultTargetPlatform == TargetPlatform.macOS
            ? null
            : 'Priorities',
        commands: [NewPriority()],
      ),
      body: BlocBuilder<LayoutBloc, LayoutState>(
        builder: (context, layoutState) {
          return Column(
            children: [
              Expanded(
                child: BlocBuilder<PrioritiesBloc, PrioritiesState>(
                  builder: (builderContext, state) {
                    return BlocBuilder<NowBloc, NowState>(
                      builder: (builderContext, priorityState) {
                        return PrioritiesList(
                          root: state.root!,
                          priorities: state.priorities,
                          selected: priorityState is NowLoaded
                              ? priorityState.context
                              : null,
                        );
                      },
                    );
                  },
                ),
              ),
              if (layoutState.multiPanel) ...[
                ListTile(
                  title: 'Twists',
                  trailingBuilder: (isHovered, hasFocus) => Icon(
                    PlotIcon.twist,
                    size: 16,
                    color: context.theme.colors.mutedForeground,
                  ),
                  command: CommandWrapper(ManageTwists(), icon: Value(null)),
                ),
                BlocBuilder<UserBloc, UserState>(
                  builder: (context, userState) {
                    if (userState is UserReady) {
                      final userName =
                          userState.user.name ??
                          userState.user.primaryEmail ??
                          'User';
                      return ListTile(
                        title: userName,
                        trailingBuilder: (isHovered, hasFocus) => Icon(
                          PlotIcon.settings,
                          size: 16,
                          color: context.theme.colors.mutedForeground,
                        ),
                        command: CommandWrapper(
                          ShowSettings(),
                          icon: Value(null),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
