import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/page/page.dart';
import 'command.dart';

class ShowAllCalendarSettings extends Command {
  ShowAllCalendarSettings()
    : super(
        title: 'Calendar Settings',
        icon: PlotIcon.settings,
        description: 'Add calendars and change sync settings',
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandCommands(
      Commands<void>(
        prompt: 'Manage calendars',
        groups: await calendarSettingsCommands(),
      ),
    );
  }
}

class EnableCalendar extends ShowCommands<Priority> {
  EnableCalendar(this.calendar)
    : super(
        title: calendar.enabled ? 'Change Default Priority' : 'Enable',
        icon: PlotIcon.add,
        commands: (context) => PickPriority(
          prompt: 'Select Default Priority for ${calendar.name}',
        ),
      );

  final Calendar calendar;

  @override
  void onSelect(BuildContext context, Priority value) async {
    try {
      await calendar
          .copyWith(priorityId: Value(value.id), enabled: true)
          .save();
    } catch (e) {
      print('Error enabling calendar: $e');
    }
  }
}

class SyncCalendar extends Command {
  SyncCalendar(this.calendar)
    : super(title: calendar.enabled ? 'Re-sync' : 'Sync', icon: PlotIcon.sync);

  final Calendar calendar;

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    await calendar.sync();
    return null;
  }
}

class ShowCalendarSettings extends Command {
  ShowCalendarSettings(this.calendar)
    : super(
        title: calendar.name,
        icon: PlotIcon.settings,
        description: 'Change sync settings',
      );

  final Calendar calendar;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandCommands(
      Commands<void>(
        prompt: 'Calendar settings for ${calendar.name}',
        groups: [
          StaticCommandGroup(
            title: 'Calendar settings for ${calendar.name}',
            commands: [EnableCalendar(calendar), SyncCalendar(calendar)],
          ),
        ],
      ),
    );
  }
}

class AddGoogleAccount extends Command {
  AddGoogleAccount() : super(title: 'Sync with Google');

  @override
  Future<CommandReturn> run(BuildContext context) async {
    return CommandPage(const AuthAccountPage());
  }
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
