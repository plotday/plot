import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:plot/command/command.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/page/loading.dart';

@RoutePage(name: "ActivityRoute")
class ActivityWrapper extends AutoRouter implements AutoRouteWrapper {
  ActivityWrapper({
    Activity? activity,
    ActivityId? activityId,
    @PathParam("activityId") String? activityIdString,
    super.key,
  }) : activityId = activity?.id ??
            activityId ??
            (activityIdString != null
                ? ActivityId.fromShortString(activityIdString)
                : null);

  final ActivityId? activityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return BlocProvider(
      create: (_) => ActivityBloc()..setCurrentId(activityId),
      child: this,
    );
  }
}

@RoutePage(name: "ActivityMainRoute")
class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ActivityBloc, ActivityState>(
      builder: (context, state) {
        if (state is! ActivitySelectedState) {
          return const LoadingPage();
        }

        if (state.loading) {
          return const LoadingPage();
        }

        return Scaffold(
          header: Header(
            title: state.current.title,
            commands: [primaryActivityCommand(state.current)],
          ),
          body: Column(
            children: [
              Flexible(
                flex: 0,
                child: Container(
                  padding: EdgeInsets.all(16),
                  child: NotesView(notes: state.pinnedNotes),
                ),
              ),
              Flexible(
                flex: 1,
                fit: FlexFit.loose,
                child: Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(width: 1.0, color: context.colour.border),
                    ),
                  ),
                  child: NotesView(notes: state.notes),
                ),
              ),
            ],
          ),
          footer: EditableArea(
            position: EditableAreaPosition.bottom,
            builder: (context, focusNode) => Editor(
              hint: 'Add a note',
              autofocus: true,
              focusNode: focusNode,
              onSubmitted: (body) async {
                await context.read<ActivityBloc>().updateNote(
                      state.draft.copyWith(body: body, draft: false),
                    );
              },
            ),
          ),
        );
      },
    );
  }
}
