import 'package:flutter/material.dart';
import 'package:flutter_adaptive_scaffold/flutter_adaptive_scaffold.dart';

import 'package:plot/page/account.dart';
import 'package:plot/page/now.dart';
import 'package:plot/page/schedule.dart';
import 'layout.dart';

class MaterialLayout extends StatefulWidget {
  static PanelLayout getLayout(BuildContext context) =>
      Breakpoints.small.isActive(context)
          ? PanelLayout.single
          : Breakpoints.medium.isActive(context)
              ? PanelLayout.double
              : PanelLayout.triple;

  const MaterialLayout(this.panels, {super.key});

  @override
  State<MaterialLayout> createState() {
    return MaterialLayoutState();
  }

  final List<Widget> panels;
}

class MaterialLayoutState extends State<MaterialLayout>
    with SingleTickerProviderStateMixin {
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
                widget.panels[0],
                const NowPage(),
                const SchedulePage(),
                const AccountPage(),
              ],
            )),
          ),
          Breakpoints.medium: SlotLayout.from(
            key: const Key('Body Medium'),
            builder: (_) => Scaffold(
                body: TabBarView(
              controller: _tabController,
              children: [
                Expanded(
                  child: widget.panels[0],
                ),
                Expanded(
                  child: widget.panels[1],
                ),
              ],
            )),
          ),
          Breakpoints.large: SlotLayout.from(
            key: const Key('Body Large'),
            builder: (_) => Row(
              children: [
                Expanded(
                  child: widget.panels[0],
                ),
                Expanded(
                  child: widget.panels[1],
                ),
                Expanded(
                  child: widget.panels[2],
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
