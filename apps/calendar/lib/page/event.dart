import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/now.dart';
import 'package:plot/util/time.dart';
import 'package:plot/platform/spinner.dart';

class EventPage extends StatelessWidget {
  const EventPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(builder: (context, state) {
      switch (state) {
        case SelectedEventLoadingState _:
          return const Center(child: Spinner());
        case SelectedEventErrorState _:
          return const Center(child: Text("Error"));
        case SelectedEventState state:
          return Column(children: [
            const Text('Event Page'),
            if (state.selected.name != null) Text(state.selected.name!),
            Text(state.selected.at.start.toDate().format()),
            Text(state.selected.at.start.toTimeOfDay().format(context)),
            Text(state.selected.at.end.toTimeOfDay().format(context)),
          ]);
      }
    });
  }
}
