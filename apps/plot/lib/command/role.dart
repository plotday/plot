import 'package:plot/analytics/profile.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/color_dot.dart';
import 'package:plot/widget/widget.dart';

import 'base.dart';
import 'role_notifications.dart';

/// Modal for creating a new [Role]. Collects name + colour only — notification
/// settings are edited later via [ShowRoleNotificationsSettings]. The created
/// role is returned to [onCreated] (used by the inline picker path) before the
/// modal closes.
class AddRole extends ShowForm {
  AddRole({this.onCreated})
    : super(
        title: 'Add a role',
        icon: PlotIcon.add,
        form: (context) async => _buildForm(onCreated: onCreated),
      );

  /// Invoked with the saved role just before the modal closes. The focus form's
  /// Role field uses this to select the freshly created role.
  final void Function(Role)? onCreated;

  static FormData _buildForm({void Function(Role)? onCreated}) {
    return FormData(
      title: 'Add a role',
      groups: [
        StaticFormGroup(
          items: [
            FormTextInput(key: 'name', label: 'Role name', required: true),
            _colorSelect(initial: const ThemeColor.defaultColor()),
            FormButton(
              key: 'create',
              isPrimary: true,
              buildCommand: (values) => _CreateRole(
                name: values['name'] as String,
                color: values['color'] as ThemeColor?,
                onCreated: onCreated,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Persists a new [Role] (pushes to `/sync/roles`; the server auto-creates the
/// role's Inbox focus and seeds notification defaults). Reports the saved role
/// to [onCreated] before completing.
class _CreateRole extends Command {
  _CreateRole({required this.name, this.color, this.onCreated})
    : super(
        title: 'Create role',
        icon: PlotIcon.save,
        // Distinct from focus (priority) create events so role vs focus
        // creation is separable in analytics.
        eventObject: EventObject.role,
        eventAction: EventAction.added,
      );

  final String name;
  final ThemeColor? color;
  final void Function(Role)? onCreated;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final role = Role.create(name: name, color: color);
    await role.save();
    onCreated?.call(role);
    // Refresh the user's role count on the next sync.
    markUserAnalyticsProfileStale();
    return const CommandDone();
  }
}

/// Opens the [AddRole] form and returns the created [Role], or null if the user
/// cancelled. Unlike [AddRole] on its own, this resolves to the new role so the
/// focus form's Role [FormSelect.onAdd] can select it inline. Mirrors
/// `createPriorityInline`.
Future<Role?> createRoleInline(BuildContext context) async {
  Role? result;
  await AddRole(onCreated: (role) => result = role).run(context);
  return result;
}

/// Modal for editing an existing role's name + colour. Notification settings
/// live in the separate [ShowRoleNotificationsSettings] modal. Changing the
/// colour fires the server's `propagate_role_to_focuses` trigger so following
/// focuses adopt it. Mirrors [EditPriorityCommand]'s structure.
class EditRoleCommand extends ShowForm {
  EditRoleCommand(Role role)
    : super(
        title: 'Edit role',
        icon: PlotIcon.settings,
        form: (context) async {
          // Re-fetch to get the latest data (e.g. after a previous save).
          final r = await Role.getOne(role.id) ?? role;
          return FormData(
            title: 'Edit role',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'name',
                    label: 'Role name',
                    initialValue: r.name,
                    required: true,
                  ),
                  _colorSelect(initial: r.displayColor),
                  FormButton(
                    key: 'save',
                    isPrimary: true,
                    buildCommand: (values) => _SaveRole(
                      r.id,
                      name: values['name'] as String,
                      color: values['color'] as ThemeColor?,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
}

/// Writes a role's name + colour and saves (pushes `/sync/roles`).
class _SaveRole extends Command {
  _SaveRole(this.roleId, {required this.name, this.color})
    : super(
        title: 'Save',
        icon: PlotIcon.done,
        eventObject: EventObject.role,
        eventAction: EventAction.updated,
      );

  final RoleId roleId;
  final String name;
  final ThemeColor? color;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final role = await Role.getOne(roleId);
    if (role == null) return const CommandDone();
    await role.copyWith(name: name, color: Value(color)).save();
    return const CommandDone();
  }
}

/// Shared "Color" [FormSelect] used by the Add/Edit role forms (mirrors the
/// focus form's colour field). [initial] seeds the selection.
FormSelect<ThemeColor> _colorSelect({required ThemeColor initial}) {
  return FormSelect<ThemeColor>(
    key: 'color',
    label: 'Color',
    initialValue: initial,
    hasInitialValue: true,
    items: (search) async => ThemeColor.options
        .where(
          (c) =>
              search == null ||
              c.label.toLowerCase().startsWith(search.toLowerCase()),
        )
        .toList(),
    titleBuilder: (c) => c.label,
    leadingBuilder: (c) => ColorDot(color: c),
  );
}

/// The role "…" menu: edit the role's name/colour and its notification
/// template. Mirrors [prioritySecondaryCommands].
List<Command> roleSecondaryCommands(Role role) => [
  EditRoleCommand(role),
  ShowRoleNotificationsSettings(role),
];

/// The role overflow menu, mirroring [ShowPriorityCommands].
class ShowRoleCommands extends ShowCommands {
  ShowRoleCommands(Role role)
    : super(
        title: 'More',
        icon: PlotIcon.menu,
        commands: Commands(
          groups: [
            StaticCommandGroup(
              title: 'Role: ${role.name}',
              commands: roleSecondaryCommands(role),
            ),
          ],
        ),
      );
}
