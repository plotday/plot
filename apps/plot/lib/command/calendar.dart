import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/page/page.dart';
import 'command.dart';
import 'logging.dart';

class ShowAllCalendarSettings extends ShowCommands {
  ShowAllCalendarSettings()
    : super(
        title: 'Calendar Settings',
        icon: PlotIcon.settings,
        description: 'Add calendars and change sync settings',
        commands: (context) async => Commands(
          prompt: 'Manage calendars',
          groups: await calendarSettingsCommands(),
        ),
      );
}

class ChangeCalendarDefaultPriority extends PriorityCommand {
  ChangeCalendarDefaultPriority(this.calendar, super.priority);

  final Calendar calendar;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await calendar
          .copyWith(priorityId: Value(priority?.id), enabled: true)
          .save();
    } catch (e, t) {
      log.warning('Error enabling calendar', e, t);
    }
    return const CommandDone();
  }
}

class EnableCalendar extends ShowCommands {
  EnableCalendar(Calendar calendar)
    : super(
        title: calendar.enabled ? 'Change Default Priority' : 'Enable',
        icon: PlotIcon.add,
        commands: (context) => Future.value(
          Commands(
            groups: [
              PriorityGroup(
                title: 'Select Default Priority for ${calendar.name}',
                builder: (priority) =>
                    ChangeCalendarDefaultPriority(calendar, priority),
              ),
            ],
          ),

          // PickPriority(prompt: 'Select Default Priority for ${calendar.name}'),
        ),
      );
}

class SyncCalendar extends Command {
  SyncCalendar(this.calendar)
    : super(title: calendar.enabled ? 'Re-sync' : 'Sync', icon: PlotIcon.sync);

  final Calendar calendar;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await calendar.sync();
    return const CommandDone();
  }
}

class ShowCalendarSettings extends ShowCommands {
  ShowCalendarSettings(Calendar calendar)
    : super(
        title: calendar.name,
        icon: PlotIcon.settings,
        description: calendar.enabled ? 'Change sync settings' : 'Enable',
        commands: (context) => Future.value(
          Commands(
            prompt: 'Calendar settings for ${calendar.name}',
            groups: [
              StaticCommandGroup(
                title: 'Calendar settings for ${calendar.name}',
                commands: [EnableCalendar(calendar), SyncCalendar(calendar)],
              ),
            ],
          ),
        ),
      );
}

class AddGoogleAccount extends ShowPage {
  AddGoogleAccount()
    : super(
        title: 'Sync with Google',
        builder: (context) => const AuthAccountPage(),
      );
}

Future<List<CommandGroup>> calendarSettingsCommands() async {
  final accounts = await Account.get(withCalendars: true);
  return [
    ...accounts.map((account) {
      final accountCalendars = account.calendars ?? [];
      return StaticCommandGroup(
        title: account.email,
        commands: accountCalendars
            .map((calendar) => ShowCalendarSettings(calendar))
            .toList(),
      );
    }),
    StaticCommandGroup(title: 'Add an Account', commands: [AddGoogleAccount()]),
  ];
}
