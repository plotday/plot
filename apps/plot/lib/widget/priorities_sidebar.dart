import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:plot/command/command.dart';
import 'priorities_tree.dart';

class PrioritiesSidebar extends StatelessWidget {
  const PrioritiesSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    return FSidebar(
      header: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Text(
                'Priorities',
                style: context.theme.typography.lg.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          FButton(
            style: FButtonStyle.ghost,
            onPress: () => NewPriority().run(context),
            child: const Icon(Icons.add, size: 16),
          ),
        ],
      ),
      children: [PrioritiesTreeWidget(isCompact: true)],
    );
  }
}
