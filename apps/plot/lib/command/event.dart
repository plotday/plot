import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/router.dart';
import 'command.dart';

class ArchiveEventCommand extends Command {
  ArchiveEventCommand(this.event)
    : super(title: 'Archive Event', icon: PlotIcon.archive);

  final Event event;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await event.copyWith(deletedAt: Value(DateTime.now())).save();
    return const CommandDone();
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
  Future<CommandReturn> run(BuildContext context) async {
    return CommandRoute(EventRoute(eventId: eventId));
  }
}

class ChangeEventPriority extends PriorityCommand {
  ChangeEventPriority(this.event, super.priority);

  final Event event;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await event.copyWith(priorityId: Value(priority?.id)).save();
    return const CommandDone();
  }
}

class PickEventPriority extends ShowCommands {
  PickEventPriority(this.event)
    : super(
        title: 'Change Priority',
        icon: PlotIcon.priority,
        commands: (context) => Future.value(
          Commands(
            groups: [
              PriorityGroup(
                title: 'Select Priority',
                builder: (priority) => ChangeEventPriority(event, priority),
              ),
            ],
          ),
        ),
      );

  final Event event;
}

class PickEventResponse extends ShowCommands {
  PickEventResponse(Event event)
    : super(
        title: 'Change Response',
        icon: PlotIcon.event,
        commands: (context) => Future.value(
          Commands(
            prompt: 'Select response',
            groups: [
              StaticCommandGroup(
                title: 'Response Options',
                commands: [
                  ChangeEventResponse(
                    event,
                    EventResponse.accepted,
                    title: 'Accepted',
                    subtitle: 'Accept this event',
                    icon: PlotIcon.done,
                  ),
                  ChangeEventResponse(
                    event,
                    EventResponse.declined,
                    title: 'Declined',
                    subtitle: 'Decline this event',
                    icon: PlotIcon.archive,
                  ),
                  ChangeEventResponse(
                    event,
                    EventResponse.tentative,
                    title: 'Tentative',
                    subtitle: 'Maybe attend this event',
                    icon: PlotIcon.priority,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

class ChangeEventResponse extends Command {
  ChangeEventResponse(
    this.event,
    this.response, {
    required super.title,
    super.subtitle,
    super.icon,
  });
  final Event event;
  final EventResponse response;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await event
        .copyWith(
          response: Value(response),
          deletedAt: response == EventResponse.declined
              ? Value(DateTime.now())
              : Value(null),
        )
        .save();
    return const CommandDone();
  }
}
