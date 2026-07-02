import 'dart:convert';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/profile_preferences.dart';
import 'package:plot/util/time.dart';
import 'package:plot/widget/form_scheduler.dart';
import 'package:plot/widget/widget.dart';

import 'base.dart';

/// Device-local SharedPreferences key for the last manually-chosen schedule
/// offset (`{"dayOffset": int, "time": "HH:MM"}`). User-specific — registered
/// in `clearUserScopedPreferences` so it never bleeds across accounts.
const String kScheduleSendDefaultKey = 'schedule_send_default';

/// The remembered schedule-send default: the last manually-chosen offset from
/// "today" plus a time of day. `dayOffset: 1, time: "09:00"` = tomorrow 9 AM.
class SendScheduleDefault {
  const SendScheduleDefault({required this.dayOffset, required this.time});

  final int dayOffset;

  /// "HH:MM" (24-hour).
  final String time;

  static SendScheduleDefault? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final dayOffset = json['dayOffset'];
      final time = json['time'];
      if (dayOffset is! int || time is! String) return null;
      final parts = time.split(':');
      if (parts.length != 2) return null;
      return SendScheduleDefault(dayOffset: dayOffset, time: time);
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode({'dayOffset': dayOffset, 'time': time});

  int get hour => int.parse(time.split(':')[0]);
  int get minute => int.parse(time.split(':')[1]);
}

/// Tomorrow at 09:00 local — the fallback default when nothing is remembered
/// (or the remembered slot has already passed today).
@visibleForTesting
DateTime tomorrow9(DateTime now) =>
    DateTime(now.year, now.month, now.day, 9).add(const Duration(days: 1));

/// The instant the picker should default to given the [remembered] offset:
/// the remembered day-offset + time applied from today, unless that instant
/// has already passed — then tomorrow 9 AM.
@visibleForTesting
DateTime rememberedDefault(SendScheduleDefault? remembered, DateTime now) {
  if (remembered == null) return tomorrow9(now);
  final candidate = DateTime(
    now.year,
    now.month,
    now.day,
    remembered.hour,
    remembered.minute,
  ).add(Duration(days: remembered.dayOffset));
  if (!candidate.isAfter(now)) return tomorrow9(now);
  return candidate;
}

/// The initial value shown when the schedule-send modal opens: the draft's
/// current schedule when set (manual re-open or send-window auto-schedule),
/// else the remembered default.
@visibleForTesting
DateTime pickerInitial(
  DateTime? currentSendAt,
  SendScheduleDefault? remembered,
  DateTime now,
) {
  if (currentSendAt != null && currentSendAt.isAfter(now)) return currentSendAt;
  return rememberedDefault(remembered, now);
}

/// The remembered default produced by manually choosing [t] at [now]:
/// calendar-day offset + time of day.
@visibleForTesting
SendScheduleDefault rememberSchedule(DateTime t, DateTime now) {
  final chosenDay = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final dayOffset = chosenDay.difference(today).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  return SendScheduleDefault(
    dayOffset: dayOffset,
    time: '${two(t.hour)}:${two(t.minute)}',
  );
}

/// Applies the chosen schedule to the composer draft. Runs from the modal's
/// primary button; [apply] is the composer's setter (null clears).
class _ApplySendSchedule extends Command {
  _ApplySendSchedule({required this.sendAt, required this.apply})
    : super(
        title: sendAt == null ? 'Clear schedule' : 'Schedule',
        icon: sendAt == null ? PlotIcon.remove : PlotIcon.later,
        eventObject: EventObject.note,
        eventAction: sendAt == null
            ? EventAction.unscheduled
            : EventAction.scheduled,
      );

  final DateTime? sendAt;
  final ValueChanged<DateTime?> apply;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final t = sendAt;
    if (t != null) {
      // Seconds zeroed (minute granularity) — the picker already clamps, this
      // is belt-and-suspenders for programmatic values.
      final zeroed = DateTime(t.year, t.month, t.day, t.hour, t.minute);
      apply(zeroed);
      await ProfilePreferences.instance.setString(
        kScheduleSendDefaultKey,
        rememberSchedule(zeroed, Time.now()).encode(),
      );
    } else {
      apply(null);
    }
    return const CommandDone();
  }
}

/// Composer clock-button command: opens the "Schedule send" modal. The title
/// doubles as the button tooltip — inactive shows "Schedule send", active
/// shows the absolute scheduled time.
class OpenScheduleSendModal extends Command {
  OpenScheduleSendModal({required this.current, required this.apply})
    : super(
        title: current == null
            ? 'Schedule send'
            : 'Scheduled for ${current.format('EEE, MMM d, h:mm a')}',
        icon: PlotIcon.later,
        eventObject: EventObject.note,
        eventAction: EventAction.opened,
      );

  /// The draft's current sendAt (null = not scheduled).
  final DateTime? current;

  /// Receives the chosen instant, or null when the user clears the schedule.
  final ValueChanged<DateTime?> apply;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await openScheduleSendModal(context, current: current, apply: apply);
    return const CommandDone();
  }
}

/// Open the "Schedule send" modal. [current] is the draft's current sendAt
/// (null = not scheduled); [apply] receives the chosen instant, or null when
/// the user clears the schedule.
Future<void> openScheduleSendModal(
  BuildContext context, {
  DateTime? current,
  required ValueChanged<DateTime?> apply,
}) async {
  final rememberedRaw = ProfilePreferences.instance.getString(
    kScheduleSendDefaultKey,
  );
  final remembered = SendScheduleDefault.decode(rememberedRaw);
  final initial = pickerInitial(current, remembered, Time.now());

  final scheduler = FormSendScheduler(key: 'send_at', initialValue: initial);

  final items = <FormItem>[
    scheduler,
    FormButton(
      key: 'submit',
      isPrimary: true,
      buildCommand: (values) => _ApplySendSchedule(
        sendAt: (values['send_at'] as DateTime?) ?? initial,
        apply: apply,
      ),
    ),
    if (current != null)
      FormButton(
        key: 'clear',
        skipValidation: true,
        buildCommand: (_) => _ApplySendSchedule(sendAt: null, apply: apply),
      ),
  ];

  final form = FormData(
    title: 'Schedule send',
    dismissable: true,
    groups: [StaticFormGroup(items: items)],
  );
  final groups = await form.list();
  if (!context.mounted) return;
  await FormModal(
    form,
    groups: groups,
    rootContext: context,
    constraints: const BoxConstraints(maxHeight: 360, maxWidth: 420),
  ).run(context);
}
