import 'dart:async';

import 'package:plot/api/api.dart' as api;
import 'package:plot/analytics/tracker.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/attention.dart';

import 'base.dart';
import 'logging.dart';

/// Modal for the per-priority "Response times" settings: a master toggle +
/// active hours + SLA for two clearly-labelled mechanisms (schedule blocks
/// vs. early notifications). Inheritance UX: when a sub-priority's value
/// equals the inherited value on save, the override is cleared instead of
/// stored, so the priority reverts to inheritance.
class ShowResponseTimesSettings extends ShowForm {
  ShowResponseTimesSettings(this.priority)
    : super(
        title: 'Response times',
        icon: PlotIcon.notification,
        form: (context) => _buildForm(context, priority),
      );

  final Priority priority;

  /// "Respond within" / "See within" preset options.
  static const _seeWithinOptions = [
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
    (
      label: '1 day',
      seeWithin: SeeWithinTime(value: 1, unit: SeeWithinUnit.days),
    ),
  ];

  static String _seeWithinLabel(SeeWithinTime t) {
    for (final option in _seeWithinOptions) {
      if (option.seeWithin.value == t.value &&
          option.seeWithin.unit == t.unit) {
        return option.label;
      }
    }
    return t.displayLabel;
  }

  static SeeWithinTime _matchOption(SeeWithinTime t) {
    for (final option in _seeWithinOptions) {
      if (option.seeWithin.value == t.value &&
          option.seeWithin.unit == t.unit) {
        return option.seeWithin;
      }
    }
    return t;
  }

  // Root defaults — used when the priority has no inherited value (e.g. the
  // server hasn't seeded the row yet or a freshly-created priority).
  static const _defaultRespondWithin = SeeWithinTime(
    value: 4,
    unit: SeeWithinUnit.hours,
  );
  static const _defaultSeeWithin = SeeWithinTime(
    value: 30,
    unit: SeeWithinUnit.minutes,
  );
  static List<AttentionWindow> get _defaultRespondWindow => const [
    AttentionWindow(days: [1, 2, 3, 4, 5], start: '09:00', end: '17:00'),
  ];
  static List<AttentionWindow> get _defaultNotifyWindow => const [
    AttentionWindow(days: [1, 2, 3, 4, 5, 6, 7], start: '08:00', end: '20:00'),
  ];

  /// Generate "HH:MM" strings every 30 minutes from 00:00 to 23:30.
  static List<String> _timeOptions() {
    final times = <String>[];
    for (int h = 0; h < 24; h++) {
      times.add('${h.toString().padLeft(2, '0')}:00');
      times.add('${h.toString().padLeft(2, '0')}:30');
    }
    return times;
  }

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
      items: (search) async => _timeOptions(),
      titleBuilder: AttentionWindow.formatTime,
    );

    endSelect = FormSelect<String>(
      key: 'end',
      label: 'To',
      initialValue: window.end,
      hasInitialValue: true,
      items: (search) async => _timeOptions(),
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
    final isRoot = priority.root;

    // Resolve inherited values (with sensible defaults if nothing is set).
    final inherited = await _resolveInherited(priority);

    // Initial (loaded) values — use stored value when present, otherwise
    // the inherited value. The "set" flags tell us whether the priority
    // itself has an override.
    final initial = _ResponseTimesValues(
      respondScheduleEnabled:
          priority.respondScheduleEnabled ?? inherited.respondScheduleEnabled,
      respondWindow: priority.respondWindows ?? inherited.respondWindow,
      respondWithin: _matchOption(
        priority.respondWithinTime ?? inherited.respondWithin,
      ),
      earlyNotificationsEnabled:
          priority.earlyNotificationsEnabled ??
          inherited.earlyNotificationsEnabled,
      notifyWindow: priority.notifyWindows ?? inherited.notifyWindow,
      seeWithin: _matchOption(
        priority.seeWithinTime ?? inherited.seeWithin,
      ),
    );

    final respondEnabledToggle = FormToggle(
      key: 'respond_schedule_enabled',
      label: 'Schedule time to respond',
      details:
          'Automatically place response blocks for unread threads within '
          'your active hours.',
      initialValue: initial.respondScheduleEnabled,
    );

    FormWindowList? respondWindowsRef;
    final respondWindowList = FormWindowList(
      key: 'respond_window',
      initialWindows: initial.respondWindow,
      onEdit: (modalContext, index) async {
        final wl = respondWindowsRef!;
        final current = wl.windows[index];
        final editResult = await _showWindowEditModal(
          modalContext,
          current,
          title: 'Respond during',
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
          days: [1, 2, 3, 4, 5],
          start: '09:00',
          end: '17:00',
        );
        final editResult = await _showWindowEditModal(
          modalContext,
          newWindow,
          title: 'Respond during',
          canRemove: false,
        );
        if (editResult != null &&
            !editResult.removed &&
            editResult.window != null) {
          respondWindowsRef!.addWindow(editResult.window!);
        }
      },
    );
    respondWindowsRef = respondWindowList;

    final respondWithinSelect = FormSelect<SeeWithinTime>(
      key: 'respond_within',
      label: 'Respond within',
      initialValue: initial.respondWithin,
      hasInitialValue: true,
      items: (search) async => _seeWithinOptions
          .where(
            (o) =>
                search == null ||
                o.label.toLowerCase().contains(search.toLowerCase()),
          )
          .map((o) => o.seeWithin)
          .toList(),
      titleBuilder: _seeWithinLabel,
    );

    final notifyEnabledToggle = FormToggle(
      key: 'early_notifications_enabled',
      label: 'Early notifications',
      details:
          'Notify when an unread thread arrives, before its response block.',
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
      items: (search) async => _seeWithinOptions
          .where(
            (o) =>
                search == null ||
                o.label.toLowerCase().contains(search.toLowerCase()),
          )
          .map((o) => o.seeWithin)
          .toList(),
      titleBuilder: _seeWithinLabel,
    );

    return FormData(
      title: 'Response times',
      groups: [
        StaticFormGroup(
          title: 'Schedule time to respond',
          items: [
            respondEnabledToggle,
            respondWindowList,
            respondWithinSelect,
          ],
        ),
        StaticFormGroup(
          title: 'Early notifications',
          items: [
            notifyEnabledToggle,
            notifyWindowList,
            seeWithinSelect,
          ],
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              isPrimary: true,
              buildCommand: (values) {
                final current = _ResponseTimesValues(
                  respondScheduleEnabled:
                      values['respond_schedule_enabled'] as bool? ??
                      initial.respondScheduleEnabled,
                  respondWindow:
                      (values['respond_window'] as List<AttentionWindow>?) ??
                      initial.respondWindow,
                  respondWithin:
                      values['respond_within'] as SeeWithinTime? ??
                      initial.respondWithin,
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

                return _SaveResponseTimes(
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

  static Future<_ResponseTimesValues> _resolveInherited(
    Priority priority,
  ) async {
    if (priority.root) {
      // Root has no ancestor; the inherited values are its own (with
      // hard-coded defaults backing the rare case where the server hasn't
      // seeded this priority yet).
      return _ResponseTimesValues(
        respondScheduleEnabled: priority.respondScheduleEnabled ?? true,
        respondWindow: priority.respondWindows ?? _defaultRespondWindow,
        respondWithin: _matchOption(
          priority.respondWithinTime ?? _defaultRespondWithin,
        ),
        earlyNotificationsEnabled: priority.earlyNotificationsEnabled ?? true,
        notifyWindow: priority.notifyWindows ?? _defaultNotifyWindow,
        seeWithin: _matchOption(priority.seeWithinTime ?? _defaultSeeWithin),
      );
    }

    // For sub-priorities, walk to the nearest ancestor whose value is set
    // (or fall back to root defaults). The server-resolved inherited
    // value is already present on the priority row, but we still need a
    // "what would I see if I cleared the override?" reference for the
    // save-time equality check. Pulling the parent priority and reading
    // its (already-inherited) value provides that reference.
    final parentId = priority.parentId;
    if (parentId == null) {
      return _resolveInherited(priority); // unreachable: non-root has parent.
    }
    final parents = await Priority.get(id: parentId, depth: 0);
    if (parents.isEmpty) {
      return _ResponseTimesValues(
        respondScheduleEnabled: true,
        respondWindow: _defaultRespondWindow,
        respondWithin: _defaultRespondWithin,
        earlyNotificationsEnabled: true,
        notifyWindow: _defaultNotifyWindow,
        seeWithin: _defaultSeeWithin,
      );
    }
    final parent = parents.first;
    return _ResponseTimesValues(
      respondScheduleEnabled: parent.respondScheduleEnabled ?? true,
      respondWindow: parent.respondWindows ?? _defaultRespondWindow,
      respondWithin: _matchOption(
        parent.respondWithinTime ?? _defaultRespondWithin,
      ),
      earlyNotificationsEnabled: parent.earlyNotificationsEnabled ?? true,
      notifyWindow: parent.notifyWindows ?? _defaultNotifyWindow,
      seeWithin: _matchOption(parent.seeWithinTime ?? _defaultSeeWithin),
    );
  }
}

/// Snapshot of the six response-time values together. Used to compare the
/// loaded ("initial") state with the user's current form state to figure
/// out which keys to push.
class _ResponseTimesValues {
  _ResponseTimesValues({
    required this.respondScheduleEnabled,
    required this.respondWindow,
    required this.respondWithin,
    required this.earlyNotificationsEnabled,
    required this.notifyWindow,
    required this.seeWithin,
  });

  final bool respondScheduleEnabled;
  final List<AttentionWindow> respondWindow;
  final SeeWithinTime respondWithin;
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

/// Command for saving an edited window in the sub-modal.
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

/// Command for removing a window in the sub-modal.
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

/// Persist the six response-time settings. Only writes keys the user
/// actually changed in this dialog; untouched keys are omitted from the
/// POST body (and from the local optimistic update) so cross-device state
/// isn't clobbered. On a sub-priority, a value that matches the inherited
/// value is sent as `null` with `set_*: true` to clear the override.
class _SaveResponseTimes extends Command {
  _SaveResponseTimes({
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
  final _ResponseTimesValues initial;
  final _ResponseTimesValues current;
  final _ResponseTimesValues inherited;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final body = <String, dynamic>{
      'priority_id': priorityId.toString(),
    };
    final companion = PrioritiesCompanion();
    var hasChanges = false;
    var notifyWindowChanged = false;

    // respond_schedule_enabled
    if (current.respondScheduleEnabled != initial.respondScheduleEnabled) {
      hasChanges = true;
      final matchesInherited = !isRoot &&
          current.respondScheduleEnabled == inherited.respondScheduleEnabled;
      body['respond_schedule_enabled'] =
          matchesInherited ? null : current.respondScheduleEnabled;
      body['set_respond_schedule_enabled'] = true;
      await _write(
        companion.copyWith(
          respondScheduleEnabled: Value(
            matchesInherited ? null : current.respondScheduleEnabled,
          ),
          respondScheduleEnabledSet: Value(!matchesInherited),
        ),
      );
    }

    // respond_window
    if (!_windowListEquals(current.respondWindow, initial.respondWindow)) {
      hasChanges = true;
      final matchesInherited = !isRoot &&
          _windowListEquals(current.respondWindow, inherited.respondWindow);
      body['respond_window'] = matchesInherited
          ? null
          : current.respondWindow.map((w) => w.toJson()).toList();
      body['set_respond_window'] = true;
      await _write(
        companion.copyWith(
          respondWindow: Value(
            matchesInherited
                ? null
                : AttentionWindow.toJsonString(current.respondWindow),
          ),
          respondWindowSet: Value(!matchesInherited),
        ),
      );
    }

    // respond_within
    if (current.respondWithin != initial.respondWithin) {
      hasChanges = true;
      final matchesInherited =
          !isRoot && current.respondWithin == inherited.respondWithin;
      body['respond_within'] =
          matchesInherited ? null : current.respondWithin.toJson();
      body['set_respond_within'] = true;
      await _write(
        companion.copyWith(
          respondWithin: Value(
            matchesInherited
                ? null
                : SeeWithinTime.toJsonString(current.respondWithin),
          ),
          respondWithinSet: Value(!matchesInherited),
        ),
      );
    }

    // early_notifications_enabled
    if (current.earlyNotificationsEnabled !=
        initial.earlyNotificationsEnabled) {
      hasChanges = true;
      final matchesInherited = !isRoot &&
          current.earlyNotificationsEnabled ==
              inherited.earlyNotificationsEnabled;
      body['early_notifications_enabled'] =
          matchesInherited ? null : current.earlyNotificationsEnabled;
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

    // notify_window
    if (!_windowListEquals(current.notifyWindow, initial.notifyWindow)) {
      hasChanges = true;
      notifyWindowChanged = true;
      final matchesInherited = !isRoot &&
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

    // see_within
    if (current.seeWithin != initial.seeWithin) {
      hasChanges = true;
      final matchesInherited =
          !isRoot && current.seeWithin == inherited.seeWithin;
      body['see_within'] =
          matchesInherited ? null : current.seeWithin.toJson();
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

    // Mirror the (possibly updated) notify_window to SharedPreferences for
    // the background notification isolate.
    if (notifyWindowChanged) {
      unawaited(syncNotifyWindowsToPrefs());
    }

    // Sync to server in background.
    unawaited(
      api
          .post<Map<String, dynamic>>('/sync/priority-attention', body: body)
          .then((_) => Priority.pull())
          .catchError((Object e) {
            log.warning('Failed to sync response-time settings', e);
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
