import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/router.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';

class NewActivity extends StatelessWidget {
  const NewActivity({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, state) => state.activity == null
            ? const Spinner()
            : Column(
                children: [
                  InputAction(
                    // TODO update body while editing
                    onAdd: (body) async {
                      Posthog().capture(
                        eventName: 'Activity Created',
                      );
                      await context.read<PriorityBloc>().updateActivity(
                          state.activity!.copyWith(body: body, draft: false));
                      if (context.mounted) {
                        ActivityRoute.byId(
                                state.activity!.priorityId, state.activity!.id)
                            .go(context);
                      }
                    },
                    label: "Create an activity",
                  ),
                ],
              ),
      );
}
