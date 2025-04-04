import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/router.dart';
import 'package:plot/state/draft_activity.dart';
import 'package:plot/state/now.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

@RoutePage(name: "NewActivityRoute")
class NewActivityWrapper extends AutoRouter implements AutoRouteWrapper {
  NewActivityWrapper({
    this.draft,
    Priority? priority,
    PriorityId? priorityId,
    @QueryParam("priorityId") String? priorityIdString,
    super.key,
  }) : priorityId =
           priority?.id ??
           priorityId ??
           (priorityIdString != null
               ? PriorityId.fromShortString(priorityIdString)
               : null);

  final Activity? draft;
  final PriorityId? priorityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return BlocProvider(
      create:
          (_) => DraftActivityBloc(
            priorityId: context.read<NowBloc>().loadedState.priority.id,
            draft: draft,
          ),
      child: this,
    );
  }
}

@RoutePage(name: "NewActivityMainRoute")
class NewActivityPage extends StatelessWidget {
  const NewActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DraftActivityBloc, DraftActivityState>(
      builder: (context, state) {
        if (state.loading) {
          return const Spinner();
        }

        return Scaffold(
          header: Header(title: 'New Activity', modal: true),
          body: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              spacing: 8,
              children: [
                Editor(
                  hint: 'Start an activity',
                  autofocus: true,
                  onChange: (body) async {
                    final activity = state.draft.copyWith(body: body);
                    await context.read<DraftActivityBloc>().updateDraft(
                      activity,
                    );
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  spacing: 8,
                  children: [
                    Row(
                      spacing: 8,
                      children: [
                        Button(
                          StartActivity(
                            state.draft,
                            onUpdate:
                                context.read<DraftActivityBloc>().updateDraft,
                          ),
                          selected: state.draft.doNow,
                        ),
                        Button(
                          PinActivity(
                            state.draft,
                            onUpdate:
                                context.read<DraftActivityBloc>().updateDraft,
                          ),
                          selected: state.draft.pinned,
                        ),
                      ],
                    ),
                    Button.primary(AddActivity(state.draft)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class AddActivity extends Command {
  AddActivity(this.activity) : super(title: 'Add');

  final Activity activity;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    final activity = this.activity.copyWith(draft: false);
    await context.read<DraftActivityBloc>().updateDraft(activity);
    Posthog().capture(eventName: 'Activity Added');
    if (context.mounted) {
      await context.router.replace(
        PriorityRoute(priorityId: activity.priorityId),
      );
    }
    return null;
  }
}
