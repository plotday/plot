import 'package:flutter/widgets.dart';

import 'package:plot/router.dart';

enum MenuSelection {
  settings,
}

class GlobalMenu extends StatefulWidget {
  static final _globalKey = GlobalKey();

  GlobalMenu({required this.child}) : super(key: _globalKey);

  @override
  State<GlobalMenu> createState() => _GlobalMenuState();

  final Widget child;
}

class _GlobalMenuState extends State<GlobalMenu> {
  @override
  Widget build(BuildContext contet) {
    return PlatformMenuBar(
      menus: <PlatformMenuItem>[
        PlatformMenu(
          label: 'Plot',
          menus: <PlatformMenuItem>[
            PlatformMenuItemGroup(
              members: <PlatformMenuItem>[
                PlatformMenuItem(
                  onSelected: () {
                    const SettingsRoute().go(context);
                  },
                  label: "Settings",
                ),
              ],
            ),
            if (PlatformProvidedMenuItem.hasMenu(
                PlatformProvidedMenuItemType.quit))
              const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.quit),
          ],
        ),
      ],
      child: widget.child,
    );
  }
}
