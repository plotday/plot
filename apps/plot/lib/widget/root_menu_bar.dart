import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/command/command.dart';
import 'package:plot/state/user.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'app_context.dart';
import 'editor.dart';

/// Root-level menu bar that persists across navigation changes.
///
/// This widget wraps the entire app with a PlatformMenuBar that updates
/// its menu items based on authentication state, without rebuilding the
/// menu bar itself during navigation.
class RootMenuBar extends StatelessWidget {
  const RootMenuBar({required this.child, super.key});

  final Widget child;

  /// Run a command using the app context (which has access to ModalProvider).
  void _runCommand(Command command) {
    final appContext = AppContext.context;
    if (appContext != null) {
      appContext.run(command);
    } else {
      debugPrint('Warning: AppContext not available for running command');
    }
  }

  List<PlatformMenuItem> _buildAppMenu(bool showUserMenus) {
    return <PlatformMenuItem>[
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.about))
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.about,
        ),
      if (showUserMenus)
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformMenuItem(
              onSelected: () => _runCommand(ShowSettings()),
              shortcut: platformSingleActivator(LogicalKeyboardKey.comma),
              label: 'Settings...',
            ),
          ],
        ),
      if (PlatformProvidedMenuItem.hasMenu(
        PlatformProvidedMenuItemType.servicesSubmenu,
      ))
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.servicesSubmenu,
        ),
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          if (PlatformProvidedMenuItem.hasMenu(
            PlatformProvidedMenuItemType.hide,
          ))
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hide,
            ),
          if (PlatformProvidedMenuItem.hasMenu(
            PlatformProvidedMenuItemType.hideOtherApplications,
          ))
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.hideOtherApplications,
            ),
          if (PlatformProvidedMenuItem.hasMenu(
            PlatformProvidedMenuItemType.showAllApplications,
          ))
            const PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.showAllApplications,
            ),
        ],
      ),
      if (showUserMenus)
        PlatformMenuItemGroup(
          members: <PlatformMenuItem>[
            PlatformMenuItem(
              onSelected: () => _runCommand(SignOut()),
              label: 'Sign Out...',
            ),
          ],
        ),
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit))
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
    ];
  }

  /// Dispatch an edit operation. Tries the active SuperEditor first, then
  /// falls back to Flutter's text editing intents for regular TextFields.
  void _editAction(
    void Function(EditorState editor) editorAction,
    Intent textFieldIntent,
  ) {
    final editor = EditorState.activeInstance;
    if (editor != null) {
      editorAction(editor);
      return;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null) {
      Actions.maybeInvoke(context, textFieldIntent);
    }
  }

  List<PlatformMenuItem> _buildEditMenu() {
    return <PlatformMenuItem>[
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performCut(),
              const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
            ),
            shortcut: platformSingleActivator(LogicalKeyboardKey.keyX),
            label: 'Cut',
          ),
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performCopy(),
              CopySelectionTextIntent.copy,
            ),
            shortcut: platformSingleActivator(LogicalKeyboardKey.keyC),
            label: 'Copy',
          ),
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performPaste(),
              const PasteTextIntent(SelectionChangedCause.keyboard),
            ),
            shortcut: platformSingleActivator(LogicalKeyboardKey.keyV),
            label: 'Paste',
          ),
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performSelectAll(),
              const SelectAllTextIntent(SelectionChangedCause.keyboard),
            ),
            shortcut: platformSingleActivator(LogicalKeyboardKey.keyA),
            label: 'Select All',
          ),
        ],
      ),
    ];
  }

  List<PlatformMenuItem> _buildViewMenu() {
    return <PlatformMenuItem>[
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformMenuItem(
            onSelected: () => _runCommand(ToggleSidebarCommand()),
            shortcut: platformSingleActivator(LogicalKeyboardKey.backslash),
            label: 'Toggle Sidebar',
          ),
        ],
      ),
    ];
  }

  List<PlatformMenuItem> _buildWindowMenu() {
    return <PlatformMenuItem>[
      if (PlatformProvidedMenuItem.hasMenu(
        PlatformProvidedMenuItemType.minimizeWindow,
      ))
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.minimizeWindow,
        ),
      if (PlatformProvidedMenuItem.hasMenu(
        PlatformProvidedMenuItemType.zoomWindow,
      ))
        const PlatformProvidedMenuItem(
          type: PlatformProvidedMenuItemType.zoomWindow,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (isMobilePlatform()) return child;

    return BlocBuilder<UserBloc, UserState>(
      builder: (context, userState) {
        final showUserMenus = userState is UserReady;

        return PlatformMenuBar(
          menus: <PlatformMenuItem>[
            PlatformMenu(label: 'Plot', menus: _buildAppMenu(showUserMenus)),
            PlatformMenu(label: 'Edit', menus: _buildEditMenu()),
            if (showUserMenus)
              PlatformMenu(label: 'View', menus: _buildViewMenu()),
            PlatformMenu(label: 'Window', menus: _buildWindowMenu()),
          ],
          child: child,
        );
      },
    );
  }
}
