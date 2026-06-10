import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import 'package:plot/widget/scaffold.dart';

@RoutePage(name: 'MoreRoute')
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    // Placeholder — Phase 4 replaces the body with the settings list.
    return const Scaffold(
      body: Center(child: Text('More')),
    );
  }
}
