import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/router.dart';
import 'command.dart';

class ArchiveEventCommand extends Command {
  ArchiveEventCommand(this.event)
    : super(title: 'Archive Event', icon: PlotIcon.delete);

  final Event event;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    // await context
    //     .read<ScheduleBloc>()
    //     .update(event.copyWith(deletedAt: Value(DateTime.now())));
    return null;
  }
}

class ChangeCurrentEvent extends Command {
  ChangeCurrentEvent(Event event)
    // ignore: prefer_initializing_formals
    : event = event,
      eventId = event.id,
      super(title: "Open", icon: PlotIcon.open);

  ChangeCurrentEvent.byId(this.eventId)
    : event = null,
      super(title: "Open", icon: PlotIcon.open);

  final Event? event;
  final EventId eventId;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await context.router.navigate(EventRoute(eventId: eventId));
    return null;
  }
}

class ChangeEventPriority extends ShowCommands<Priority> {
  ChangeEventPriority(this.event)
    : super(
        title: 'Change Priority',
        icon: PlotIcon.priority,
        commands: (context) => PickPriority(prompt: 'Pick priority for event'),
      );

  final Event event;

  @override
  void onSelect(BuildContext context, Priority value) async {
    // await context
    //     .read<ScheduleBloc>()
    //     .update(event.copyWith(priorityId: Value(value.id)));
  }
}
