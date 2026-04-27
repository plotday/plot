import 'dart:async';

import 'package:plot/api/api.dart' as api;
import 'package:plot/analytics/tracker.dart';
import 'package:plot/notifications/notification_service.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/attention.dart';

import 'base.dart';
import 'logging.dart';

class ShowAttentionSettings extends ShowForm {
  ShowAttentionSettings(this.priority)
    : super(
        title: 'Notifications',
        icon: PlotIcon.notification,
        form: (context) => _buildForm(context, priority),
      );

  final Priority priority;

  /// See within preset options with display labels.
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

  static const _defaultSeeWithinRequests = SeeWithinTime(
    value: 30,
    unit: SeeWithinUnit.minutes,
  );
  static const _defaultSeeWithinUpdates = SeeWithinTime(
    value: 1,
    unit: SeeWithinUnit.hours,
  );

  static SeeWithinTime _matchSeeWithin(
    SeeWithinTime? t,
    SeeWithinTime fallback,
  ) {
    if (t == null) return _matchOption(fallback);
    return _matchOption(t);
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
  /// Returns the edited window, or null if removed.
  static Future<_WindowEditResult?> _showWindowEditModal(
    BuildContext context,
    AttentionWindow window, {
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
      title: 'Quiet hours',
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
    final windows = priority.attentionWindows;
    final seeWithinRequests = priority.seeWithinRequestsTime;
    final seeWithinUpdates = priority.seeWithinUpdatesTime;

    // Get inherited values for comparison on save
    final inheritedWindows = isRoot
        ? (windows ?? AttentionWindow.defaultQuietHours)
        : await _getInheritedWindows(priority);
    final inheritedSeeWithinRequests = isRoot
        ? _matchSeeWithin(seeWithinRequests, _defaultSeeWithinRequests)
        : await _getInheritedSeeWithinRequests(priority);
    final inheritedSeeWithinUpdates = isRoot
        ? _matchSeeWithin(seeWithinUpdates, _defaultSeeWithinUpdates)
        : await _getInheritedSeeWithinUpdates(priority);

    FormWindowList? windowListRef;

    // Quiet hours window list
    final windowList = FormWindowList(
      key: 'windows',
      initialWindows: windows ?? inheritedWindows,
      onEdit: (modalContext, index) async {
        final wl = windowListRef!;
        final current = wl.windows[index];
        final editResult = await _showWindowEditModal(
          modalContext,
          current,
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
          start: '21:00',
          end: '07:00',
        );
        final editResult = await _showWindowEditModal(
          modalContext,
          newWindow,
          canRemove: false,
        );
        if (editResult != null &&
            !editResult.removed &&
            editResult.window != null) {
          windowListRef!.addWindow(editResult.window!);
        }
      },
    );
    windowListRef = windowList;

    // See within requests field
    final seeWithinRequestsSelect = FormSelect<SeeWithinTime>(
      key: 'see_within_requests',
      label: 'See requests within',
      initialValue: _matchSeeWithin(
        seeWithinRequests ?? inheritedSeeWithinRequests,
        _defaultSeeWithinRequests,
      ),
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

    // See within updates field
    final seeWithinUpdatesSelect = FormSelect<SeeWithinTime>(
      key: 'see_within_updates',
      label: 'See updates within',
      initialValue: _matchSeeWithin(
        seeWithinUpdates ?? inheritedSeeWithinUpdates,
        _defaultSeeWithinUpdates,
      ),
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
      title: 'Notifications',
      groups: [
        StaticFormGroup(
          items: [seeWithinRequestsSelect, seeWithinUpdatesSelect],
        ),
        StaticFormGroup(title: 'Quiet hours', items: [windowList]),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              isPrimary: true,
              buildCommand: (values) {
                final windowValues = values['windows'] as List<AttentionWindow>;
                final selectedSeeWithinRequests =
                    values['see_within_requests'] as SeeWithinTime;
                final selectedSeeWithinUpdates =
                    values['see_within_updates'] as SeeWithinTime;

                // Compare with inherited to decide override vs clear
                final windowsSame = _windowListEquals(
                  windowValues,
                  inheritedWindows,
                );
                final seeWithinRequestsSame =
                    selectedSeeWithinRequests == inheritedSeeWithinRequests;
                final seeWithinUpdatesSame =
                    selectedSeeWithinUpdates == inheritedSeeWithinUpdates;

                return _SaveAttentionSettings(
                  priorityId: priority.id,
                  attentionWindow: isRoot || !windowsSame ? windowValues : null,
                  setAttentionWindow: isRoot || !windowsSame,
                  seeWithinRequests: isRoot || !seeWithinRequestsSame
                      ? selectedSeeWithinRequests
                      : null,
                  setSeeWithinRequests: isRoot || !seeWithinRequestsSame,
                  seeWithinUpdates: isRoot || !seeWithinUpdatesSame
                      ? selectedSeeWithinUpdates
                      : null,
                  setSeeWithinUpdates: isRoot || !seeWithinUpdatesSame,
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  static bool _windowListEquals(
    List<AttentionWindow> a,
    List<AttentionWindow> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<List<AttentionWindow>> _getInheritedWindows(
    Priority priority,
  ) async {
    if (!priority.attentionWindowSet) {
      return priority.attentionWindows ?? AttentionWindow.defaultQuietHours;
    }
    final parentId = priority.parentId;
    if (parentId == null) return AttentionWindow.defaultQuietHours;
    final parents = await Priority.get(id: parentId, depth: 0);
    if (parents.isEmpty) return AttentionWindow.defaultQuietHours;
    return parents.first.attentionWindows ?? AttentionWindow.defaultQuietHours;
  }

  static Future<SeeWithinTime> _getInheritedSeeWithinRequests(
    Priority priority,
  ) async {
    if (!priority.seeWithinRequestsSet) {
      return _matchSeeWithin(
        priority.seeWithinRequestsTime,
        _defaultSeeWithinRequests,
      );
    }
    final parentId = priority.parentId;
    if (parentId == null) {
      return _matchSeeWithin(null, _defaultSeeWithinRequests);
    }
    final parents = await Priority.get(id: parentId, depth: 0);
    if (parents.isEmpty) {
      return _matchSeeWithin(null, _defaultSeeWithinRequests);
    }
    return _matchSeeWithin(
      parents.first.seeWithinRequestsTime,
      _defaultSeeWithinRequests,
    );
  }

  static Future<SeeWithinTime> _getInheritedSeeWithinUpdates(
    Priority priority,
  ) async {
    if (!priority.seeWithinUpdatesSet) {
      return _matchSeeWithin(
        priority.seeWithinUpdatesTime,
        _defaultSeeWithinUpdates,
      );
    }
    final parentId = priority.parentId;
    if (parentId == null) {
      return _matchSeeWithin(null, _defaultSeeWithinUpdates);
    }
    final parents = await Priority.get(id: parentId, depth: 0);
    if (parents.isEmpty) return _matchSeeWithin(null, _defaultSeeWithinUpdates);
    return _matchSeeWithin(
      parents.first.seeWithinUpdatesTime,
      _defaultSeeWithinUpdates,
    );
  }
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

class _SaveAttentionSettings extends Command {
  _SaveAttentionSettings({
    required this.priorityId,
    required this.attentionWindow,
    required this.setAttentionWindow,
    required this.seeWithinRequests,
    required this.setSeeWithinRequests,
    required this.seeWithinUpdates,
    required this.setSeeWithinUpdates,
  }) : super(
         title: 'Save',
         icon: PlotIcon.done,
         eventObject: EventObject.priority,
         eventAction: EventAction.updated,
       );

  final PriorityId priorityId;
  final List<AttentionWindow>? attentionWindow;
  final bool setAttentionWindow;
  final SeeWithinTime? seeWithinRequests;
  final bool setSeeWithinRequests;
  final SeeWithinTime? seeWithinUpdates;
  final bool setSeeWithinUpdates;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Write to local DB first (optimistic update)
    await (Store.get.update(
      Store.get.priorities,
    )..where((t) => t.id.equalsValue(priorityId))).write(
      PrioritiesCompanion(
        attentionWindow: setAttentionWindow
            ? Value(AttentionWindow.toJsonString(attentionWindow))
            : const Value.absent(),
        attentionWindowSet: setAttentionWindow
            ? const Value(true)
            : const Value.absent(),
        seeWithinRequests: setSeeWithinRequests
            ? Value(SeeWithinTime.toJsonString(seeWithinRequests))
            : const Value.absent(),
        seeWithinRequestsSet: setSeeWithinRequests
            ? const Value(true)
            : const Value.absent(),
        seeWithinUpdates: setSeeWithinUpdates
            ? Value(SeeWithinTime.toJsonString(seeWithinUpdates))
            : const Value.absent(),
        seeWithinUpdatesSet: setSeeWithinUpdates
            ? const Value(true)
            : const Value.absent(),
      ),
    );

    // Sync attention windows to SharedPreferences for background handler
    if (setAttentionWindow) {
      unawaited(syncAttentionWindowsToPrefs());
    }

    // Sync to server in background
    unawaited(
      api
          .post<Map<String, dynamic>>(
            '/sync/priority-attention',
            body: {
              'priority_id': priorityId.toString(),
              'attention_window': attentionWindow
                  ?.map((w) => w.toJson())
                  .toList(),
              'set_attention_window': setAttentionWindow,
              'see_within_requests': seeWithinRequests?.toJson(),
              'set_see_within_requests': setSeeWithinRequests,
              'see_within_updates': seeWithinUpdates?.toJson(),
              'set_see_within_updates': setSeeWithinUpdates,
            },
          )
          .then((_) => Priority.pull())
          .catchError((Object e) {
            log.warning('Failed to sync attention settings', e);
          }),
    );

    return const CommandDone();
  }
}

class SetAttentionWindow extends Command {
  SetAttentionWindow(this.priorityId, this.windows)
    : super(
        title: 'Set quiet hours',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;
  final List<AttentionWindow>? windows;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Write to local DB first (optimistic update)
    await (Store.get.update(
      Store.get.priorities,
    )..where((t) => t.id.equalsValue(priorityId))).write(
      PrioritiesCompanion(
        attentionWindow: Value(AttentionWindow.toJsonString(windows)),
        attentionWindowSet: const Value(true),
      ),
    );

    // Sync attention windows to SharedPreferences for background handler
    unawaited(syncAttentionWindowsToPrefs());

    // Sync to server in background
    unawaited(
      api
          .post<Map<String, dynamic>>(
            '/sync/priority-attention',
            body: {
              'priority_id': priorityId.toString(),
              'attention_window': windows?.map((w) => w.toJson()).toList(),
              'set_attention_window': true,
            },
          )
          .then((_) => Priority.pull())
          .catchError((Object e) {
            log.warning('Failed to sync attention window', e);
          }),
    );

    return const CommandDone();
  }
}

class ClearAttentionWindow extends Command {
  ClearAttentionWindow(this.priorityId)
    : super(
        title: 'Clear quiet hours',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Write to local DB first (optimistic update)
    await (Store.get.update(
      Store.get.priorities,
    )..where((t) => t.id.equalsValue(priorityId))).write(
      const PrioritiesCompanion(
        attentionWindow: Value(null),
        attentionWindowSet: Value(true),
      ),
    );

    // Sync attention windows to SharedPreferences for background handler
    unawaited(syncAttentionWindowsToPrefs());

    // Sync to server in background
    unawaited(
      api
          .post<Map<String, dynamic>>(
            '/sync/priority-attention',
            body: {
              'priority_id': priorityId.toString(),
              'attention_window': null,
              'set_attention_window': true,
            },
          )
          .then((_) => Priority.pull())
          .catchError((Object e) {
            log.warning('Failed to sync clear attention window', e);
          }),
    );

    return const CommandDone();
  }
}
