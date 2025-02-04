import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/router.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class PrioritiesNav extends StatelessWidget {
  const PrioritiesNav({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PrioritiesBloc, PrioritiesState>(
      builder: (context, state) {
        return Column(
          children: [
            ListTile(
              title: const Text('All'),
              onTap: () => const PrioritiesRoute.all().go(context),
            ),
          ],
        );
      },
    );
  }
}

class PrioritiesHeader extends StatelessWidget {
  const PrioritiesHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Header(title: 'Priorities');
  }
}

class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PrioritiesBloc, PrioritiesState>(
      builder: (context, state) {
        return Column(
          children: [
            WeekSelector(
              week: state.week,
              onSelect: (week) => context.read<PrioritiesBloc>().setWeek(week),
            ),
            ReorderableListView(
              list: state.filtered,
              itemBuilder: (context, item) => PriorityTile(
                  priority: item,
                  balances: state.balances?[item.id],
                  isNow: state.week.isNow(),
                  onTap: () {
                    if (item.id == null) return;
                    PriorityRoute.byId(item.id).go(context);
                  }),
              shrinkWrap: true,
              onReorder: (int oldIndex, int newIndex) async {
                var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                Priority? previous;
                if (previousIndex >= 0) {
                  previous = state.filtered[previousIndex];
                }
                Priority? next;
                if (nextIndex < state.filtered.length) {
                  next = state.filtered[nextIndex];
                }
                state.filtered[oldIndex]
                    .copyWith(
                      order: Order.between(previous?.order, next?.order),
                    )
                    .save();
              },
            ),
          ],
        );
      },
    );
  }
}
