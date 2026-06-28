import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/api/iap_api.dart';
import 'package:plot/command/command.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/user.dart';
import 'package:plot/util/developer_mode.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'app_context.dart';
import 'editor.dart';
import 'modal.dart';

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
              label: 'Sign out...',
            ),
          ],
        ),
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit))
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
    ];
  }

  /// Dispatch an edit operation. Tries the active SuperEditor first, then
  /// falls back to Flutter's text editing intents for regular TextFields.
  ///
  /// When a modal is open, the active SuperEditor is skipped — its `perform*`
  /// methods call `requestFocus()` on the underlying focus node, which would
  /// steal focus from a TextField inside the modal. `activeInstance` is
  /// intentionally not cleared on blur (see EditorState._onFocusChange), so
  /// the modal-open check is the chokepoint that keeps shortcuts routed to
  /// the modal's focused widget instead of the background editor.
  void _editAction(
    void Function(EditorState editor) editorAction,
    Intent textFieldIntent,
  ) {
    final editor =
        ModalProvider.hasOpenModals ? null : EditorState.activeInstance;
    if (editor != null) {
      editorAction(editor);
      return;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null) {
      Actions.maybeInvoke(context, textFieldIntent);
    }
  }

  /// When [suppressShortcuts] is true, the Edit items keep their labels but drop
  /// their key equivalents. macOS matches a `PlatformMenuBar` item's shortcut
  /// app-wide (ahead of the native first responder), so an active Cmd+V/C/X/A
  /// accelerator is captured by Flutter even while a native StoreKit sheet is
  /// up — breaking paste into its password field. Dropping the accelerators
  /// while the sheet is present lets those keys fall through to the native
  /// field. See [IapService.nativeSheetActive].
  List<PlatformMenuItem> _buildEditMenu({bool suppressShortcuts = false}) {
    return <PlatformMenuItem>[
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performUndo(),
              const UndoTextIntent(SelectionChangedCause.keyboard),
            ),
            shortcut: suppressShortcuts
                ? null
                : platformSingleActivator(LogicalKeyboardKey.keyZ),
            label: 'Undo',
          ),
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performRedo(),
              const RedoTextIntent(SelectionChangedCause.keyboard),
            ),
            shortcut: suppressShortcuts
                ? null
                : platformSingleActivator(LogicalKeyboardKey.keyZ, shift: true),
            label: 'Redo',
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performCut(),
              const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
            ),
            shortcut: suppressShortcuts
                ? null
                : platformSingleActivator(LogicalKeyboardKey.keyX),
            label: 'Cut',
          ),
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performCopy(),
              CopySelectionTextIntent.copy,
            ),
            shortcut: suppressShortcuts
                ? null
                : platformSingleActivator(LogicalKeyboardKey.keyC),
            label: 'Copy',
          ),
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performPaste(),
              const PasteTextIntent(SelectionChangedCause.keyboard),
            ),
            shortcut: suppressShortcuts
                ? null
                : platformSingleActivator(LogicalKeyboardKey.keyV),
            label: 'Paste',
          ),
          PlatformMenuItem(
            onSelected: () => _editAction(
              (e) => e.performSelectAll(),
              const SelectAllTextIntent(SelectionChangedCause.keyboard),
            ),
            shortcut: suppressShortcuts
                ? null
                : platformSingleActivator(LogicalKeyboardKey.keyA),
            label: 'Select all',
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
            label: 'Toggle sidebar',
          ),
        ],
      ),
    ];
  }

  List<PlatformMenuItem> _buildTimerMenu(NowState nowState) {
    final loaded = nowState is NowLoaded ? nowState : null;
    final hasContext = loaded?.context != null;
    final inactive =
        loaded?.pomodoroState == PomodoroState.inactive || loaded == null;
    return <PlatformMenuItem>[
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformMenuItem(
            onSelected: hasContext
                ? () => _runCommand(inactive ? StartTimer() : StopTimer())
                : null,
            shortcut: timerToggleShortcut,
            label: inactive ? 'Start focus' : 'Pause focus',
          ),
          if (!inactive)
            PlatformMenuItem(
              onSelected: () => _runCommand(EndTimer()),
              shortcut: timerEndShortcut,
              label: 'Stop focus',
            ),
        ],
      ),
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformMenuItem(
            onSelected: hasContext ? () => _runCommand(AddTime()) : null,
            shortcut: timerAddShortcut,
            label: 'Add time',
          ),
          PlatformMenuItem(
            onSelected: hasContext ? () => _runCommand(RemoveTime()) : null,
            shortcut: timerRemoveShortcut,
            label: 'Remove 15 minutes',
          ),
        ],
      ),
    ];
  }

  List<PlatformMenuItem> _buildDebugMenu() {
    final group = buildDebugCommands();
    if (group == null) return const <PlatformMenuItem>[];
    return group.commands
        .map(
          (cmd) => PlatformMenuItem(
            onSelected: () => _runCommand(cmd),
            label: cmd.title,
          ),
        )
        .toList();
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

        return ListenableBuilder(
          listenable: DeveloperMode.notifier,
          builder: (context, _) {
            final showDebug = kDebugMode || DeveloperMode.isEnabled;
            return BlocBuilder<NowBloc, NowState>(
              builder: (context, nowState) => ValueListenableBuilder<bool>(
                // Drop the Edit accelerators while a native StoreKit sheet is up
                // so Cmd+V etc. reach its password field (see _buildEditMenu).
                valueListenable: IapService.nativeSheetActive,
                builder: (context, sheetActive, _) => PlatformMenuBar(
                  menus: <PlatformMenuItem>[
                    PlatformMenu(
                      label: 'Plot',
                      menus: _buildAppMenu(showUserMenus),
                    ),
                    PlatformMenu(
                      label: 'Edit',
                      menus: _buildEditMenu(suppressShortcuts: sheetActive),
                    ),
                    if (showUserMenus)
                      PlatformMenu(label: 'View', menus: _buildViewMenu()),
                    if (showUserMenus)
                      PlatformMenu(
                        label: 'Timer',
                        menus: _buildTimerMenu(nowState),
                      ),
                    PlatformMenu(label: 'Window', menus: _buildWindowMenu()),
                    if (showDebug)
                      PlatformMenu(label: 'Debug', menus: _buildDebugMenu()),
                  ],
                  child: child,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
