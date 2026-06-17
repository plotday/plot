import 'dart:async';

import 'package:plot/api/api.dart' as api;
import 'package:plot/analytics/tracker.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/attention.dart';

import 'base.dart';
import 'logging.dart';

/// "See within" preset options, shared by the per-focus
/// ([ShowEarlyNotificationsSettings]) and per-role
/// ([ShowRoleNotificationsSettings]) notification editors.
const seeWithinOptions = <({String label, SeeWithinTime seeWithin})>[
  (
    label: 'Immediately',
    seeWithin: SeeWithinTime(value: 0, unit: SeeWithinUnit.minutes),
  ),
  (
    label: '15 minutes',
    seeWithin: SeeWithinTime(value: 15, unit: SeeWithinUnit.minutes),
  ),
  (
    label: '30 minutes',
    seeWithin: SeeWithinTime(value: 30, unit: SeeWithinUnit.minutes),
  ),
  (
    label: '1 hour',
    seeWithin: SeeWithinTime(value: 1, unit: SeeWithinUnit.hours),
  ),
  (
    label: '2 hours',
    seeWithin: SeeWithinTime(value: 2, unit: SeeWithinUnit.hours),
  ),
  (
    label: '4 hours',
    seeWithin: SeeWithinTime(value: 4, unit: SeeWithinUnit.hours),
  ),
  (
    label: 'Same day',
    seeWithin: SeeWithinTime(value: 0, unit: SeeWithinUnit.days),
  ),
  (label: '1 day', seeWithin: SeeWithinTime(value: 1, unit: SeeWithinUnit.days)),
];

/// Label for a "see within" time, matching it against [seeWithinOptions] and
/// falling back to its generic display label.
String seeWithinLabel(SeeWithinTime t) {
  for (final option in seeWithinOptions) {
    if (option.seeWithin.value == t.value && option.seeWithin.unit == t.unit) {
      return option.label;
    }
  }
  return t.displayLabel;
}

/// Snaps a "see within" time to the canonical option instance when one matches
/// (so [FormSelect] equality lines up), otherwise returns it unchanged.
SeeWithinTime matchSeeWithinOption(SeeWithinTime t) {
  for (final option in seeWithinOptions) {
    if (option.seeWithin.value == t.value && option.seeWithin.unit == t.unit) {
      return option.seeWithin;
    }
  }
  return t;
}

/// "HH:MM" strings every 30 minutes from 00:00 to 23:30, for time selects.
List<String> notifyTimeOptions() {
  final times = <String>[];
  for (int h = 0; h < 24; h++) {
    times.add('${h.toString().padLeft(2, '0')}:00');
    times.add('${h.toString().padLeft(2, '0')}:30');
  }
  return times;
}

/// Modal for the per-priority notification settings: a master toggle +
/// active hours + see-within deadline. Inheritance UX: when a sub-priority's
/// value equals the inherited value on save, the override is cleared instead
/// of stored, so the priority reverts to inheritance.
class ShowEarlyNotificationsSettings extends ShowForm {
  ShowEarlyNotificationsSettings(this.priority)
    : super(
        title: 'Notifications',
        icon: PlotIcon.notification,
        form: (context) => _buildForm(context, priority),
      );

  final Priority priority;

  /// User-facing focus name for titles/copy. The root focus is always shown
  /// as "Inbox" regardless of its stored title.
  static String _focusName(Priority priority) => priority.displayTitle;

  static const _defaultSeeWithin = SeeWithinTime(
    value: 30,
    unit: SeeWithinUnit.minutes,
  );
  static List<AttentionWindow> get _defaultNotifyWindow => const [
    AttentionWindow(days: [1, 2, 3, 4, 5, 6, 7], start: '08:00', end: '20:00'),
  ];

  /// Show the sub-modal for editing a single attention window.
  /// Returns the edited window, or null if removed/cancelled.
  static Future<_WindowEditResult?> _showWindowEditModal(
    BuildContext context,
    AttentionWindow window, {
    required String title,
    required bool canRemove,
  }) async {
    _WindowEditResult? result;

    final dayToggles = <int, FormToggle>{};
    for (int d = 1; d <= 7; d++) {
      dayToggles[d] = FormToggle(
        key: 'day_$d',
        label: AttentionWindow.dayLabels[d - 1],
        initialValue: window.days.contains(d),
      );
    }

    late final FormSelect<String> startSelect;
    late final FormSelect<String> endSelect;

    startSelect = FormSelect<String>(
      key: 'start',
      label: 'From',
      initialValue: window.start,
      hasInitialValue: true,
      items: (search) async => notifyTimeOptions(),
      titleBuilder: AttentionWindow.formatTime,
    );

    endSelect = FormSelect<String>(
      key: 'end',
      label: 'To',
      initialValue: window.end,
      hasInitialValue: true,
      items: (search) async => notifyTimeOptions(),
      titleBuilder: AttentionWindow.formatTime,
    );

    final dayItems = dayToggles.values.cast<FormItem>().toList();
    final timeItems = <FormItem>[startSelect, endSelect];

    final actionItems = <FormItem>[
      FormButton(
        key: 'save_window',
        isPrimary: true,
        buildCommand: (values) {
          return _WindowSaveCommand(
            dayToggles: dayToggles,
            startSelect: startSelect,
            endSelect: endSelect,
            onResult: (r) => result = r,
          );
        },
      ),
    ];

    if (canRemove) {
      actionItems.add(
        FormButton(
          key: 'remove_window',
          buildCommand: (values) {
            return _WindowRemoveCommand(onResult: (r) => result = r);
          },
        ),
      );
    }

    final formData = FormData(
      title: title,
      groups: [
        StaticFormGroup(title: 'Days', items: dayItems),
        StaticFormGroup(title: 'Time', items: timeItems),
        StaticFormGroup(items: actionItems),
      ],
    );

    final groups = await formData.list();
    if (!context.mounted) return null;

    await FormModal(
      formData,
      groups: groups,
      rootContext: context,
    ).run(context);
    return result;
  }

  static Future<FormData> _buildForm(
    BuildContext context,
    Priority priority,
  ) async {
    final isRoot = priority.isInbox;

    final inherited = await _resolveInherited(priority);

    final initial = _EarlyNotificationsValues(
      earlyNotificationsEnabled:
          priority.earlyNotificationsEnabled ??
          inherited.earlyNotificationsEnabled,
      notifyWindow: priority.notifyWindows ?? inherited.notifyWindow,
      seeWithin: matchSeeWithinOption(priority.seeWithinTime ?? inherited.seeWithin),
    );

    final notifyEnabledToggle = FormToggle(
      key: 'early_notifications_enabled',
      label: 'Notifications',
      details: isRoot
          ? 'Notify for new and updated threads in the Inbox.'
          : 'Notify for new and updated threads in this focus.',
      initialValue: initial.earlyNotificationsEnabled,
    );

    FormWindowList? notifyWindowsRef;
    final notifyWindowList = FormWindowList(
      key: 'notify_window',
      initialWindows: initial.notifyWindow,
      onEdit: (modalContext, index) async {
        final wl = notifyWindowsRef!;
        final current = wl.windows[index];
        final editResult = await _showWindowEditModal(
          modalContext,
          current,
          title: 'Notify during',
          canRemove: true,
        );
        if (editResult == null) return;
        if (editResult.removed) {
          wl.removeWindow(index);
        } else if (editResult.window != null) {
          wl.updateWindow(index, editResult.window!);
        }
      },
      onAdd: (modalContext) async {
        final newWindow = const AttentionWindow(
          days: [1, 2, 3, 4, 5, 6, 7],
          start: '08:00',
          end: '20:00',
        );
        final editResult = await _showWindowEditModal(
          modalContext,
          newWindow,
          title: 'Notify during',
          canRemove: false,
        );
        if (editResult != null &&
            !editResult.removed &&
            editResult.window != null) {
          notifyWindowsRef!.addWindow(editResult.window!);
        }
      },
    );
    notifyWindowsRef = notifyWindowList;

    final seeWithinSelect = FormSelect<SeeWithinTime>(
      key: 'see_within',
      label: 'See within',
      initialValue: initial.seeWithin,
      hasInitialValue: true,
      items: (search) async => seeWithinOptions
          .where(
            (o) =>
                search == null ||
                o.label.toLowerCase().contains(search.toLowerCase()),
          )
          .map((o) => o.seeWithin)
          .toList(),
      titleBuilder: seeWithinLabel,
    );

    return FormData(
      title: 'Notifications for ${_focusName(priority)}',
      groups: [
        StaticFormGroup(
          items: [notifyEnabledToggle, seeWithinSelect, notifyWindowList],
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              isPrimary: true,
              buildCommand: (values) {
                final current = _EarlyNotificationsValues(
                  earlyNotificationsEnabled:
                      values['early_notifications_enabled'] as bool? ??
                      initial.earlyNotificationsEnabled,
                  notifyWindow:
                      (values['notify_window'] as List<AttentionWindow>?) ??
                      initial.notifyWindow,
                  seeWithin:
                      values['see_within'] as SeeWithinTime? ??
                      initial.seeWithin,
                );

                return _SaveEarlyNotifications(
                  priorityId: priority.id,
                  isRoot: isRoot,
                  initial: initial,
                  current: current,
                  inherited: inherited,
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  static Future<_EarlyNotificationsValues> _resolveInherited(
    Priority priority,
  ) async {
    if (priority.isInbox) {
      return _EarlyNotificationsValues(
        earlyNotificationsEnabled: priority.earlyNotificationsEnabled ?? true,
        notifyWindow: priority.notifyWindows ?? _defaultNotifyWindow,
        seeWithin: matchSeeWithinOption(priority.seeWithinTime ?? _defaultSeeWithin),
      );
    }

    final parentId = priority.parentId;
    if (parentId == null) {
      return _resolveInherited(priority); // unreachable: non-root has parent.
    }
    final parents = await Priority.get(id: parentId, depth: 0);
    if (parents.isEmpty) {
      return _EarlyNotificationsValues(
        earlyNotificationsEnabled: true,
        notifyWindow: _defaultNotifyWindow,
        seeWithin: _defaultSeeWithin,
      );
    }
    final parent = parents.first;
    return _EarlyNotificationsValues(
      earlyNotificationsEnabled: parent.earlyNotificationsEnabled ?? true,
      notifyWindow: parent.notifyWindows ?? _defaultNotifyWindow,
      seeWithin: matchSeeWithinOption(parent.seeWithinTime ?? _defaultSeeWithin),
    );
  }
}

/// Snapshot of the three early-notification values together. Used to compare
/// the loaded ("initial") state with the user's current form state to figure
/// out which keys to push.
class _EarlyNotificationsValues {
  _EarlyNotificationsValues({
    required this.earlyNotificationsEnabled,
    required this.notifyWindow,
    required this.seeWithin,
  });

  final bool earlyNotificationsEnabled;
  final List<AttentionWindow> notifyWindow;
  final SeeWithinTime seeWithin;
}

bool _windowListEquals(List<AttentionWindow> a, List<AttentionWindow> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Result from the window edit sub-modal.
class _WindowEditResult {
  final AttentionWindow? window;
  final bool removed;

  const _WindowEditResult({this.window}) : removed = false;
  const _WindowEditResult.remove() : window = null, removed = true;
}

class _WindowSaveCommand extends Command {
  _WindowSaveCommand({
    required this.dayToggles,
    required this.startSelect,
    required this.endSelect,
    required this.onResult,
  }) : super(
         title: 'Save',
         icon: PlotIcon.done,
         eventObject: EventObject.modal,
         eventAction: EventAction.updated,
       );

  final Map<int, FormToggle> dayToggles;
  final FormSelect<String> startSelect;
  final FormSelect<String> endSelect;
  final void Function(_WindowEditResult) onResult;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final days = <int>[];
    for (int d = 1; d <= 7; d++) {
      if (dayToggles[d]!.getValue()) days.add(d);
    }

    if (days.isEmpty) {
      return const CommandMessage('Select at least one day', isError: true);
    }

    final start = startSelect.getValue()!;
    final end = endSelect.getValue()!;

    onResult(
      _WindowEditResult(
        window: AttentionWindow(days: days, start: start, end: end),
      ),
    );
    return const CommandDone();
  }
}

class _WindowRemoveCommand extends Command {
  _WindowRemoveCommand({required this.onResult})
    : super(
        title: 'Remove',
        icon: PlotIcon.remove,
        eventObject: EventObject.modal,
        eventAction: EventAction.updated,
      );

  final void Function(_WindowEditResult) onResult;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    onResult(const _WindowEditResult.remove());
    return const CommandDone();
  }
}

/// Persist the three early-notification settings. Only writes keys the user
/// actually changed in this dialog; untouched keys are omitted from the
/// POST body so cross-device state isn't clobbered. On a sub-priority, a
/// value that matches the inherited value is sent as `null` with
/// `set_*: true` to clear the override.
class _SaveEarlyNotifications extends Command {
  _SaveEarlyNotifications({
    required this.priorityId,
    required this.isRoot,
    required this.initial,
    required this.current,
    required this.inherited,
  }) : super(
         title: 'Save',
         icon: PlotIcon.done,
         eventObject: EventObject.priority,
         eventAction: EventAction.updated,
       );

  final PriorityId priorityId;
  final bool isRoot;
  final _EarlyNotificationsValues initial;
  final _EarlyNotificationsValues current;
  final _EarlyNotificationsValues inherited;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final body = <String, dynamic>{'priority_id': priorityId.toString()};
    final companion = PrioritiesCompanion();
    var hasChanges = false;
    var notifyWindowChanged = false;

    if (current.earlyNotificationsEnabled !=
        initial.earlyNotificationsEnabled) {
      hasChanges = true;
      final matchesInherited =
          !isRoot &&
          current.earlyNotificationsEnabled ==
              inherited.earlyNotificationsEnabled;
      body['early_notifications_enabled'] = matchesInherited
          ? null
          : current.earlyNotificationsEnabled;
      body['set_early_notifications_enabled'] = true;
      await _write(
        companion.copyWith(
          earlyNotificationsEnabled: Value(
            matchesInherited ? null : current.earlyNotificationsEnabled,
          ),
          earlyNotificationsEnabledSet: Value(!matchesInherited),
        ),
      );
    }

    if (!_windowListEquals(current.notifyWindow, initial.notifyWindow)) {
      hasChanges = true;
      notifyWindowChanged = true;
      final matchesInherited =
          !isRoot &&
          _windowListEquals(current.notifyWindow, inherited.notifyWindow);
      body['notify_window'] = matchesInherited
          ? null
          : current.notifyWindow.map((w) => w.toJson()).toList();
      body['set_notify_window'] = true;
      await _write(
        companion.copyWith(
          notifyWindow: Value(
            matchesInherited
                ? null
                : AttentionWindow.toJsonString(current.notifyWindow),
          ),
          notifyWindowSet: Value(!matchesInherited),
        ),
      );
    }

    if (current.seeWithin != initial.seeWithin) {
      hasChanges = true;
      final matchesInherited =
          !isRoot && current.seeWithin == inherited.seeWithin;
      body['see_within'] = matchesInherited ? null : current.seeWithin.toJson();
      body['set_see_within'] = true;
      await _write(
        companion.copyWith(
          seeWithin: Value(
            matchesInherited
                ? null
                : SeeWithinTime.toJsonString(current.seeWithin),
          ),
          seeWithinSet: Value(!matchesInherited),
        ),
      );
    }

    if (!hasChanges) {
      return const CommandDone();
    }

    if (notifyWindowChanged) {
      unawaited(syncNotifyWindowsToPrefs());
    }

    unawaited(
      api
          .post<Map<String, dynamic>>('/sync/priority-attention', body: body)
          .then((_) => Priority.pull())
          .catchError((Object e) {
            log.warning('Failed to sync early-notification settings', e);
          }),
    );

    return const CommandDone();
  }

  Future<void> _write(PrioritiesCompanion companion) async {
    await (Store.get.update(
      Store.get.priorities,
    )..where((t) => t.id.equalsValue(priorityId))).write(companion);
  }
}
