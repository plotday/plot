import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';

import 'package:plot/widget/scaffold.dart';

@RoutePage(name: 'SearchRoute')
class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Placeholder — Phase 3 replaces the body with the global search UI.
    return const Scaffold(
      body: Center(child: Text('Search')),
    );
  }
}
