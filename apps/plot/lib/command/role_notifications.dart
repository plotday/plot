import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';
import 'package:plot/store/attention.dart';
import 'package:plot/widget/widget.dart';

import 'base.dart';
import 'early_notifications.dart';

/// Modal for a [Role]'s notification template: a master toggle + active hours +
/// see-within deadline. Unlike the per-focus editor
/// ([ShowEarlyNotificationsSettings]), a role's values are absolute — there is
/// no inheritance or `*_set` flags. Saving writes the three fields straight onto
/// the role and pushes `/sync/roles`; the server's `propagate_role_to_focuses`
/// trigger then updates the focuses that follow the role.
class ShowRoleNotificationsSettings extends ShowForm {
  ShowRoleNotificationsSettings(this.role)
    : super(
        title: 'Notifications',
        icon: PlotIcon.notification,
        form: (context) => _buildForm(role),
      );

  final Role role;

  static const _defaultSeeWithin = SeeWithinTime(
    value: 30,
    unit: SeeWithinUnit.minutes,
  );
  static List<AttentionWindow> get _defaultNotifyWindow => const [
    AttentionWindow(days: [1, 2, 3, 4, 5, 6, 7], start: '08:00', end: '20:00'),
  ];

  /// Show the sub-modal for editing a single attention window. Returns the
  /// edited window, or null if removed/cancelled. Mirrors the per-focus editor.
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

    final startSelect = FormSelect<String>(
      key: 'start',
      label: 'From',
      initialValue: window.start,
      hasInitialValue: true,
      items: (search) async => notifyTimeOptions(),
      titleBuilder: AttentionWindow.formatTime,
    );

    final endSelect = FormSelect<String>(
      key: 'end',
      label: 'To',
      initialValue: window.end,
      hasInitialValue: true,
      items: (search) async => notifyTimeOptions(),
      titleBuilder: AttentionWindow.formatTime,
    );

    final actionItems = <FormItem>[
      FormButton(
        key: 'save_window',
        isPrimary: true,
        buildCommand: (values) => _WindowSaveCommand(
          dayToggles: dayToggles,
          startSelect: startSelect,
          endSelect: endSelect,
          onResult: (r) => result = r,
        ),
      ),
      if (canRemove)
        FormButton(
          key: 'remove_window',
          buildCommand: (values) =>
              _WindowRemoveCommand(onResult: (r) => result = r),
        ),
    ];

    final formData = FormData(
      title: title,
      groups: [
        StaticFormGroup(
          title: 'Days',
          items: dayToggles.values.cast<FormItem>().toList(),
        ),
        StaticFormGroup(title: 'Time', items: [startSelect, endSelect]),
        StaticFormGroup(items: actionItems),
      ],
    );

    final groups = await formData.list();
    if (!context.mounted) return null;

    await FormModal(formData, groups: groups, rootContext: context).run(context);
    return result;
  }

  static Future<FormData> _buildForm(Role role) async {
    // Re-fetch to get the latest data (e.g. after a previous save).
    final r = await Role.getOne(role.id) ?? role;

    final initialEnabled = r.earlyNotificationsEnabled ?? true;
    final initialWindows = r.notifyWindows ?? _defaultNotifyWindow;
    final initialSeeWithin = matchSeeWithinOption(
      r.seeWithinTime ?? _defaultSeeWithin,
    );

    final notifyEnabledToggle = FormToggle(
      key: 'early_notifications_enabled',
      label: 'Notifications',
      details: 'Notify for new and updated threads in this role’s focuses.',
      initialValue: initialEnabled,
    );

    FormWindowList? notifyWindowsRef;
    final notifyWindowList = FormWindowList(
      key: 'notify_window',
      initialWindows: initialWindows,
      onEdit: (modalContext, index) async {
        final wl = notifyWindowsRef!;
        final editResult = await _showWindowEditModal(
          modalContext,
          wl.windows[index],
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
        const newWindow = AttentionWindow(
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
      initialValue: initialSeeWithin,
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
      title: 'Notifications for ${r.name}',
      groups: [
        StaticFormGroup(
          items: [notifyEnabledToggle, seeWithinSelect, notifyWindowList],
        ),
        StaticFormGroup(
          items: [
            FormButton(
              key: 'save',
              isPrimary: true,
              buildCommand: (values) => _SaveRoleNotifications(
                roleId: r.id,
                notifyEnabled:
                    values['early_notifications_enabled'] as bool? ??
                    initialEnabled,
                windows:
                    (values['notify_window'] as List<AttentionWindow>?) ??
                    initialWindows,
                seeWithin:
                    values['see_within'] as SeeWithinTime? ?? initialSeeWithin,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Result from the window edit sub-modal.
class _WindowEditResult {
  const _WindowEditResult({this.window}) : removed = false;
  const _WindowEditResult.remove() : window = null, removed = true;

  final AttentionWindow? window;
  final bool removed;
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
    onResult(
      _WindowEditResult(
        window: AttentionWindow(
          days: days,
          start: startSelect.getValue()!,
          end: endSelect.getValue()!,
        ),
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

/// Persists a role's three notification settings and pushes `/sync/roles`. A
/// role's values are absolute (no inheritance), so all three are always written
/// — the server's `propagate_role_to_focuses` trigger fans them out to the
/// focuses that follow the role.
class _SaveRoleNotifications extends Command {
  _SaveRoleNotifications({
    required this.roleId,
    required this.notifyEnabled,
    required this.windows,
    required this.seeWithin,
  }) : super(
         title: 'Save',
         icon: PlotIcon.done,
         eventObject: EventObject.priority,
         eventAction: EventAction.updated,
       );

  final RoleId roleId;
  final bool notifyEnabled;
  final List<AttentionWindow> windows;
  final SeeWithinTime seeWithin;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final role = await Role.getOne(roleId);
    if (role == null) return const CommandDone();
    await role
        .copyWith(
          earlyNotificationsEnabled: Value(notifyEnabled),
          notifyWindow: Value(AttentionWindow.toJsonString(windows)),
          seeWithin: Value(SeeWithinTime.toJsonString(seeWithin)),
        )
        .save();
    return const CommandDone();
  }
}
