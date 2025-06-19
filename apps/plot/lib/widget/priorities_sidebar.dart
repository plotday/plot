import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'priorities_tree.dart';

class PrioritiesSidebar extends StatelessWidget {
  const PrioritiesSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    return FSidebar(children: [PrioritiesTreeWidget(isCompact: true)]);
  }
}
