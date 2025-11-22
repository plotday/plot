import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart' hide Scaffold;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/command/command.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/now.dart';
import 'package:plot/widget/priorities_list.dart';
import 'package:plot/widget/scaffold.dart';
import 'package:plot/widget/header.dart';

@RoutePage(name: 'PrioritiesRoute')
class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      scrollable: false,
      header: Header(title: 'Priorities', commands: [NewPriority()]),
      body: BlocBuilder<PrioritiesBloc, PrioritiesState>(
        builder: (builderContext, state) {
          return BlocBuilder<NowBloc, NowState>(
            builder: (builderContext, nowState) {
              return PrioritiesList(
                root: state.root!,
                priorities: state.priorities,
                selected: nowState is NowLoaded ? nowState.priority : null,
              );
            },
          );
        },
      ),
    );
  }
}
