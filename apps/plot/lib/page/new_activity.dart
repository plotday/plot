import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/action/action.dart';

@RoutePage()
class NewActivityPage extends StatelessWidget {
  const NewActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            return Scaffold(
              translucent: true,
              scrollable: false,
              header: layoutState.middlePanelVisible
                  ? null
                  : Header(
                      title: 'New Activity',
                      prefixActions: [
                        ActionWrapper(
                          ChangeCurrentActivity(null),
                          icon: Value(PlotIcon.back),
                        ),
                      ],
                    ),
              body: ActivityEditor(draft: state.draft, expand: true),
            );
          },
        );
      },
    );
  }
}
