import 'package:plot/api/api.dart' as api;
import 'package:plot/api/api_exception.dart';
import 'package:plot/api/network_exception.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/attention.dart';

import 'base.dart';

class ShowAttentionSettings extends ShowForm {
  ShowAttentionSettings(this.priority)
    : super(
        title: 'Attention',
        icon: PlotIcon.later,
        form: (context) => _buildForm(context, priority),
      );

  final Priority priority;

  /// See within preset options with display labels.
  static const _seeWithinOptions = [
    (
      label: 'Immediate',
      seeWithin: SeeWithinTime(value: 0, unit: SeeWithinUnit.hours),
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
      label: 'Next day',
      seeWithin: SeeWithinTime(value: 1, unit: SeeWithinUnit.days),
    ),
    (
      label: 'Next workday',
      seeWithin: SeeWithinTime(value: 1, unit: SeeWithinUnit.workdays),
    ),
    (
      label: '2 days',
      seeWithin: SeeWithinTime(value: 2, unit: SeeWithinUnit.days),
    ),
    (
      label: '2 workdays',
      seeWithin: SeeWithinTime(value: 2, unit: SeeWithinUnit.workdays),
    ),
    (
      label: '3 days',
      seeWithin: SeeWithinTime(value: 3, unit: SeeWithinUnit.days),
    ),
    (
      label: '3 workdays',
      seeWithin: SeeWithinTime(value: 3, unit: SeeWithinUnit.workdays),
    ),
    (
      label: '4 days',
      seeWithin: SeeWithinTime(value: 4, unit: SeeWithinUnit.days),
    ),
    (
      label: '4 workdays',
      seeWithin: SeeWithinTime(value: 4, unit: SeeWithinUnit.workdays),
    ),
    (
      label: '5 days',
      seeWithin: SeeWithinTime(value: 5, unit: SeeWithinUnit.days),
    ),
    (
      label: '5 workdays',
      seeWithin: SeeWithinTime(value: 5, unit: SeeWithinUnit.workdays),
    ),
    (
      label: '6 days',
      seeWithin: SeeWithinTime(value: 6, unit: SeeWithinUnit.days),
    ),
    (
      label: '1 week',
      seeWithin: SeeWithinTime(value: 7, unit: SeeWithinUnit.days),
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

  static SeeWithinTime _matchSeeWithin(SeeWithinTime? t) {
    if (t == null) return _seeWithinOptions[6].seeWithin; // Next workday
    for (final option in _seeWithinOptions) {
      if (option.seeWithin.value == t.value &&
          option.seeWithin.unit == t.unit) {
        return option.seeWithin;
      }
    }
    return _seeWithinOptions[6].seeWithin; // Next workday
  }

  /// Generate "HH:MM" strings every 30 minutes from 05:00 to 23:30.
  static List<String> _timeOptions() {
    final times = <String>[];
    for (int h = 5; h < 24; h++) {
      times.add('${h.toString().padLeft(2, '0')}:00');
      times.add('${h.toString().padLeft(2, '0')}:30');
    }
    return times;
  }

  /// Filter time options to only include times strictly after [after].
  static List<String> _timeOptionsAfter(String after) {
    return _timeOptions().where((t) => t.compareTo(after) > 0).toList();
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
      onChanged: () {
        final fromValue = startSelect.getValue()!;
        final toValue = endSelect.getValue();
        // If current "To" is not after "From", auto-adjust
        if (toValue == null || toValue.compareTo(fromValue) <= 0) {
          final validOptions = _timeOptionsAfter(fromValue);
          if (validOptions.isNotEmpty) {
            endSelect.setValue(validOptions.first);
          }
        }
      },
    );

    endSelect = FormSelect<String>(
      key: 'end',
      label: 'To',
      initialValue: window.end,
      hasInitialValue: true,
      items: (search) async {
        final fromValue = startSelect.getValue() ?? '05:00';
        return _timeOptionsAfter(fromValue);
      },
      titleBuilder: AttentionWindow.formatTime,
    );

    final dayItems = dayToggles.values.cast<FormItem>().toList();
    final timeItems = <FormItem>[startSelect, endSelect];

    final actionItems = <FormItem>[
      FormButton(
        key: 'save_window',
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
      title: 'Attention time',
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
    final seeWithin = priority.seeWithinTime;

    // Get inherited values for comparison on save
    final inheritedWindows = isRoot
        ? (windows ?? AttentionWindow.defaultBusinessHours)
        : await _getInheritedWindows(priority);
    final inheritedSeeWithin = isRoot
        ? _matchSeeWithin(seeWithin)
        : await _getInheritedSeeWithin(priority);

    FormWindowList? windowListRef;

    // Attention window list
    final windowList = FormWindowList(
      key: 'windows',
      initialWindows: windows ?? inheritedWindows,
      onEdit: (modalContext, index) async {
        final wl = windowListRef!;
        final current = wl.windows[index];
        final editResult = await _showWindowEditModal(
          modalContext,
          current,
          canRemove: wl.windows.length > 1,
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

    // See within field - single dropdown
    final seeWithinSelect = FormSelect<SeeWithinTime>(
      key: 'see_within',
      label: 'See within',
      initialValue: _matchSeeWithin(seeWithin ?? inheritedSeeWithin),
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
      title: 'Attention',
      groups: [
        StaticFormGroup(items: [seeWithinSelect]),
        StaticFormGroup(title: 'Attention times', items: [windowList]),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              buildCommand: (values) {
                final windowValues = values['windows'] as List<AttentionWindow>;
                final selectedSeeWithin = values['see_within'] as SeeWithinTime;

                // Compare with inherited to decide override vs clear
                final windowsSame = _windowListEquals(
                  windowValues,
                  inheritedWindows,
                );
                final seeWithinSame = selectedSeeWithin == inheritedSeeWithin;

                return _SaveAttentionSettings(
                  priorityId: priority.id,
                  attentionWindow: isRoot || !windowsSame ? windowValues : null,
                  setAttentionWindow: isRoot || !windowsSame,
                  seeWithin: isRoot || !seeWithinSame
                      ? selectedSeeWithin
                      : null,
                  setSeeWithin: isRoot || !seeWithinSame,
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
      return priority.attentionWindows ?? AttentionWindow.defaultBusinessHours;
    }
    final parentId = priority.parentId;
    if (parentId == null) return AttentionWindow.defaultBusinessHours;
    final parents = await Priority.get(id: parentId, depth: 0);
    if (parents.isEmpty) return AttentionWindow.defaultBusinessHours;
    return parents.first.attentionWindows ??
        AttentionWindow.defaultBusinessHours;
  }

  static Future<SeeWithinTime> _getInheritedSeeWithin(Priority priority) async {
    if (!priority.seeWithinSet) {
      return _matchSeeWithin(priority.seeWithinTime);
    }
    final parentId = priority.parentId;
    if (parentId == null) return _matchSeeWithin(null);
    final parents = await Priority.get(id: parentId, depth: 0);
    if (parents.isEmpty) return _matchSeeWithin(null);
    return _matchSeeWithin(parents.first.seeWithinTime);
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
    required this.seeWithin,
    required this.setSeeWithin,
  }) : super(
         title: 'Save',
         icon: PlotIcon.done,
         eventObject: EventObject.priority,
         eventAction: EventAction.updated,
       );

  final PriorityId priorityId;
  final List<AttentionWindow>? attentionWindow;
  final bool setAttentionWindow;
  final SeeWithinTime? seeWithin;
  final bool setSeeWithin;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-attention',
        body: {
          'priority_id': priorityId.toString(),
          'attention_window': attentionWindow?.map((w) => w.toJson()).toList(),
          'set_attention_window': setAttentionWindow,
          'see_within': seeWithin?.toJson(),
          'set_see_within': setSeeWithin,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class SetAttentionWindow extends Command {
  SetAttentionWindow(this.priorityId, this.windows)
    : super(
        title: 'Set attention time',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;
  final List<AttentionWindow>? windows;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-attention',
        body: {
          'priority_id': priorityId.toString(),
          'attention_window': windows?.map((w) => w.toJson()).toList(),
          'set_attention_window': true,
          'set_see_within': false,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class SetSeeWithin extends Command {
  SetSeeWithin(this.priorityId, this.seeWithin)
    : super(
        title: 'Set see within',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;
  final SeeWithinTime? seeWithin;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-attention',
        body: {
          'priority_id': priorityId.toString(),
          'see_within': seeWithin?.toJson(),
          'set_attention_window': false,
          'set_see_within': true,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class ClearAttentionWindow extends Command {
  ClearAttentionWindow(this.priorityId)
    : super(
        title: 'Clear attention time',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-attention',
        body: {
          'priority_id': priorityId.toString(),
          'attention_window': null,
          'set_attention_window': true,
          'set_see_within': false,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}

class ClearSeeWithin extends Command {
  ClearSeeWithin(this.priorityId)
    : super(
        title: 'Clear see within',
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
      );

  final PriorityId priorityId;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      await api.post<Map<String, dynamic>>(
        '/sync/priority-attention',
        body: {
          'priority_id': priorityId.toString(),
          'see_within': null,
          'set_attention_window': false,
          'set_see_within': true,
        },
      );
      await Priority.pull();
      return const CommandDone();
    } on ApiException catch (e) {
      return CommandMessage(e.description, title: e.title, isError: true);
    } on NetworkException catch (e) {
      return CommandMessage('Network error: ${e.message}', isError: true);
    }
  }
}
