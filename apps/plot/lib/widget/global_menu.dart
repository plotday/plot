import 'package:flutter/widgets.dart';

import 'package:plot/action/action.dart';

enum MenuSelection { settings }

class GlobalMenu extends StatelessWidget {
  const GlobalMenu({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(
      menus: <PlatformMenuItem>[
        PlatformMenu(
          label: 'Plot',
          menus: <PlatformMenuItem>[
            PlatformMenuItemGroup(
              members: <PlatformMenuItem>[
                PlatformMenuItem(
                  onSelected: () {
                    context.run(ShowSettings());
                  },
                  label: "Settings",
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
  }
}
