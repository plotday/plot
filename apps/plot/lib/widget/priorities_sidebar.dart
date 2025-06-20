import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/priorities.dart';
import 'priorities_tree.dart';

class PrioritiesSidebar extends StatelessWidget {
  const PrioritiesSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PrioritiesBloc, PrioritiesState>(
      builder: (context, state) {
        return FSidebar(
          children: [
            PrioritiesTreeWidget(
              priorities: state.priorities,
              isCompact: true,
            ),
          ],
        );
      },
    );
  }
}
