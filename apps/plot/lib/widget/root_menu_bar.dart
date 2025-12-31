import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/command/command.dart';
import 'package:plot/state/user.dart';
import 'app_context.dart';

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

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserBloc, UserState>(
      builder: (context, state) {
        // Only show menu items when user is signed in
        final showUserMenus = state is UserReady;

        return PlatformMenuBar(
          menus: <PlatformMenuItem>[
            PlatformMenu(
              label: 'Plot',
              menus: <PlatformMenuItem>[
                if (showUserMenus)
                  PlatformMenuItemGroup(
                    members: <PlatformMenuItem>[
                      PlatformMenuItem(
                        onSelected: () {
                          _runCommand(ShowSettings());
                        },
                        label: "Settings",
                      ),
                      PlatformMenuItem(
                        onSelected: () {
                          _runCommand(SignOut());
                        },
                        label: "Sign Out",
                      ),
                    ],
                  ),
                if (PlatformProvidedMenuItem.hasMenu(
                  PlatformProvidedMenuItemType.quit,
                ))
                  const PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.quit,
                  ),
              ],
            ),
          ],
          child: child,
        );
      },
    );
  }
}
