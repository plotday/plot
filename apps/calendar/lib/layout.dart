import 'package:flutter/material.dart';
import 'package:flutter_adaptive_scaffold/flutter_adaptive_scaffold.dart';

import 'account/page.dart';
import 'now/page.dart';
import 'priority/page.dart';
import 'schedule/page.dart';

class Layout extends StatefulWidget {
  const Layout({this.left = const PrioritiesPage(), super.key});

  final Widget left;

  @override
  State<Layout> createState() => LayoutState();
}

class LayoutState extends State<Layout> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int selectedNavigation = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this, initialIndex: 1);
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveLayout(
      body: SlotLayout(
        config: <Breakpoint, SlotLayoutConfig>{
          Breakpoints.small: SlotLayout.from(
            key: const Key('Body Small'),
            builder: (_) => Scaffold(
                body: TabBarView(
              controller: _tabController,
              children: [
                widget.left,
                const NowPage(),
                const SchedulePage(),
                const AccountPage(),
              ],
            )),
          ),
          Breakpoints.large: SlotLayout.from(
            key: const Key('Body Medium'),
            builder: (_) => Row(
              children: [
                Expanded(
                  child: widget.left,
                ),
                const Expanded(
                  child: NowPage(),
                ),
                const Expanded(
                  child: SchedulePage(),
                ),
              ],
            ),
          )
        },
      ),
      bottomNavigation: SlotLayout(
        config: <Breakpoint, SlotLayoutConfig>{
          Breakpoints.small: SlotLayout.from(
            key: const Key('Bottom Navigation Small'),
            inAnimation: AdaptiveScaffold.bottomToTop,
            outAnimation: AdaptiveScaffold.topToBottom,
            builder: (_) => AdaptiveScaffold.standardBottomNavigationBar(
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.crisis_alert),
                  label: 'Priorities',
                ),
                NavigationDestination(
                  icon: Icon(Icons.schedule),
                  label: 'Now',
                ),
                NavigationDestination(
                  icon: Icon(Icons.calendar_today),
                  label: 'Schedule',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
              currentIndex: _tabController.index,
              onDestinationSelected: (int index) {
                setState(() {
                  _tabController.animateTo(index);
                });
              },
            ),
          )
        },
      ),
    );
  }
}
