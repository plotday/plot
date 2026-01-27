import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/util/time_service.dart';
import 'package:plot/widget/modal.dart';
import 'command.dart';

/// Debug command group - only available in kDebugMode
final debugCommands = kDebugMode
    ? StaticCommandGroup(
        title: 'Debug',
        commands: [TimeTravel(), if (Time.isFrozen()) UnfreezeTime()],
      )
    : null;

/// Command to freeze time to a specific date/time for testing and screenshots.
class TimeTravel extends ShowPage {
  TimeTravel()
    : super(
        title: 'Time Travel',
        icon: FontAwesomeIcons.clock,
        builder: (context) => _TimeTravelPage(),
      );
}

/// Command to unfreeze time and return to live time.
class UnfreezeTime extends Command {
  UnfreezeTime()
    : super(
        title: 'Unfreeze Time',
        subtitle: 'Return to live time',
        icon: FontAwesomeIcons.clockRotateLeft,
        eventObject: EventObject.settings,
        eventAction: EventAction.clicked,
      );

  @override
  Future<CommandReturn> run(BuildContext context) async {
    Time.unfreeze();
    return CommandMessage('Time unfrozen - returned to live time');
  }
}

class _TimeTravelPage extends StatefulWidget {
  @override
  State<_TimeTravelPage> createState() => _TimeTravelPageState();
}

class _TimeTravelPageState extends State<_TimeTravelPage> {
  late FCalendarController<DateTime?> _calendarController;
  late TextEditingController _hourController;
  late TextEditingController _minuteController;
  DateTime? _selectedDate;
  int _selectedHour = 12;
  int _selectedMinute = 0;

  @override
  void initState() {
    super.initState();
    // Use frozen time if available, otherwise current time
    final initial = Time.now();
    _selectedDate = DateTime(initial.year, initial.month, initial.day);
    _selectedHour = initial.hour;
    _selectedMinute = initial.minute;

    _calendarController = FCalendarController.date(initial: _selectedDate);

    _hourController = TextEditingController(
      text: _selectedHour.toString().padLeft(2, '0'),
    );
    _minuteController = TextEditingController(
      text: _selectedMinute.toString().padLeft(2, '0'),
    );

    // Listen to text field changes to update hour/minute as user types
    _hourController.addListener(_onHourChanged);
    _minuteController.addListener(_onMinuteChanged);
  }

  void _onHourChanged() {
    final value = _hourController.text;
    final hour = int.tryParse(value);
    if (hour != null && hour >= 0 && hour <= 23) {
      setState(() {
        _selectedHour = hour;
      });
    }
  }

  void _onMinuteChanged() {
    final value = _minuteController.text;
    final minute = int.tryParse(value);
    if (minute != null && minute >= 0 && minute <= 59) {
      setState(() {
        _selectedMinute = minute;
      });
    }
  }

  @override
  void dispose() {
    _hourController.removeListener(_onHourChanged);
    _minuteController.removeListener(_onMinuteChanged);
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  void _freezeTime() {
    if (_selectedDate == null) {
      Modal.pop(
        context,
        Value(CommandMessage('Please select a date', isError: true)),
      );
      return;
    }

    try {
      final frozenTime = DateTime(
        _selectedDate!.year,
        _selectedDate!.month,
        _selectedDate!.day,
        _selectedHour,
        _selectedMinute,
      );

      Time.setFrozenTime(frozenTime);
      Modal.pop(context, Value(CommandMessage('Time frozen to $frozenTime')));
    } catch (e) {
      Modal.pop(
        context,
        Value(CommandMessage('Failed to freeze time: $e', isError: true)),
      );
    }
  }

  void _unfreezeTime() {
    Time.unfreeze();
    Modal.pop(
      context,
      Value(CommandMessage('Time unfrozen - returned to live time')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: widgetPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Time Travel',
                style: context.theme.typography.xl2.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            // Status
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                Time.isFrozen()
                    ? 'Currently frozen to: ${Time.now()}'
                    : 'Currently: Live time',
                style: context.theme.typography.sm.copyWith(
                  color: context.theme.plotColors.muted,
                ),
              ),
            ),

            // Calendar
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Center(
                child: FCalendar(
                  control: .managedDate(controller: _calendarController),
                  style: (style) =>
                      style.copyWith(decoration: const BoxDecoration()),
                  onPress: (date) {
                    setState(() {
                      _selectedDate = date;
                    });
                  },
                ),
              ),
            ),

            // Time picker
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hour',
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.plotColors.muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        FTextField(
                          control: .managed(controller: _hourController),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Minute',
                          style: context.theme.typography.sm.copyWith(
                            color: context.theme.plotColors.muted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        FTextField(
                          control: .managed(controller: _minuteController),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Actions
            Row(
              children: [
                Expanded(
                  child: FButton(
                    onPress: _freezeTime,
                    style: FButtonStyle.primary(),
                    child: const Text('Freeze Time'),
                  ),
                ),
                if (Time.isFrozen()) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: FButton(
                      onPress: _unfreezeTime,
                      style: FButtonStyle.outline(),
                      child: const Text('Unfreeze'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
