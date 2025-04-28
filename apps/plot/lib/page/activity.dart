import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:plot/command/command.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note.dart';
import 'package:plot/page/loading.dart';

@RoutePage(name: "PriorityRoute")
class PriorityWrapper extends AutoRouter implements AutoRouteWrapper {
  PriorityWrapper({
    Priority? priority,
    PriorityId? priorityId,
    @PathParam("priorityId") String? priorityIdString,
    super.key,
  }) : priorityId =
           priority?.id ??
           priorityId ??
           (priorityIdString != null
               ? PriorityId.fromShortString(priorityIdString)
               : null);

  final PriorityId? priorityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return BlocProvider(
      create: (_) => PriorityBloc()..setCurrentId(priorityId),
      child: this,
    );
  }
}

@RoutePage(name: "PriorityMainRoute")
class PriorityPage extends StatelessWidget {
  const PriorityPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        if (state is! PrioritySelectedState) {
          return const LoadingPage();
        }

        if (state.loading) {
          return const LoadingPage();
        }

        return Scaffold(
          header: Header(
            title: state.current.title,
            commands: [primaryPriorityCommand(state.current)],
          ),
          body: Column(
            children: [
              if (state.pinnedNotes.isNotEmpty)
                Flexible(
                  flex: 0,
                  fit: FlexFit.loose,
                  child: Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 1.0,
                          color: context.colour.border,
                        ),
                      ),
                    ),
                    child: NotesView(
                      notes: state.pinnedNotes,
                      shrinkWrap: true,
                    ),
                  ),
                ),
              Flexible(
                flex: 1,
                fit: FlexFit.tight,
                child: Container(
                  padding: EdgeInsets.all(16),
                  child: NotesView(notes: state.notes, reverse: true),
                ),
              ),
            ],
          ),
          footer: EditableArea(
            position: EditableAreaPosition.bottom,
            builder:
                (context, focusNode) => Editor(
                  hint: 'Add a note',
                  autofocus: true,
                  focusNode: focusNode,
                  onSubmitted: (body) async {
                    await context.read<PriorityBloc>().updateNote(
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
