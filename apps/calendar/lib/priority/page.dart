import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'package:plot/util/time_widget.dart';

import 'activity.dart';
import 'context.dart';
import 'priority.dart';
import 'bloc.dart';
import '../now/bloc.dart';
import '../util/cached_reorderable_list_view.dart';

class NewPriorityPage extends StatefulWidget {
  const NewPriorityPage({super.key});

  @override
  State<NewPriorityPage> createState() => _NewPriorityPageState();
}

class _NewPriorityPageState extends State<NewPriorityPage> {
  Context? _context;
  final TextEditingController _contextController = TextEditingController();
  final TextEditingController _activityController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(title: const Text('Add Priority')),
        body: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 8),
              DropdownMenu<Context>(
                controller: _contextController,
                label: const Text('Context'),
                expandedInsets: const EdgeInsets.all(8),
                initialSelection: _context,
                onSelected: (Context? context) {
                  setState(() {
                    _context = context;
                  });
                },
                dropdownMenuEntries: Context.list()
                    .map<DropdownMenuEntry<Context>>((Context context) {
                  return DropdownMenuEntry<Context>(
                    value: context,
                    label: context.name,
                    // style: MenuItemButton.styleFrom(
                    //   foregroundColor: context.color,
                    // ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              DropdownMenu<Activity>(
                controller: _activityController,
                label: const Text('Activity'),
                expandedInsets: const EdgeInsets.all(8),
                onSelected: (Activity? activity) {
                  setState(() {});
                },
                dropdownMenuEntries: Activity.list()
                    .map<DropdownMenuEntry<Activity>>((Activity activity) {
                  return DropdownMenuEntry<Activity>(
                    value: activity,
                    label: activity.name,
                    // style: MenuItemButton.styleFrom(
                    //   foregroundColor: activity.color,
                    // ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    child: const Text('Cancel'),
                    onPressed: () {
                      context.pop();
                    },
                  ),
                  TextButton(
                    child: const Text('Add'),
                    onPressed: () async {
                      if (_context == null) {
                        _context = Context(name: _contextController.text);
                        context
                            .read<PrioritiesBloc>()
                            .add(ContextAdded(_context!));
                      }
                      final activity = Activity(
                          name: _activityController.text, context: _context!);
                      context
                          .read<PrioritiesBloc>()
                          .add(ActivityAdded(activity));
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go('/');
                      }
                    },
                  ),
                ],
              )
            ],
          ),
        ));
  }
}

class PriorityWidget extends StatelessWidget {
  const PriorityWidget({required this.priority, super.key});
  final Priority priority;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey(priority.activity?.id.toString() ?? 0),
      onTap: () {
        if (priority.activity == null) {
          return;
        }
        context.read<NowBloc>().add(ActivitySelected(priority.activity!));
      },
      title: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(priority.activity?.name ?? 'Other'),
        Row(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Padding(
                  padding: EdgeInsets.only(
                      bottom: 2.0), // Add 2px padding at the bottom
                  child: Icon(Icons.hourglass_bottom, size: 14),
                ),
                DurationWidget(duration: priority.planned),
              ],
            ),
            const SizedBox(width: 8),
            MenuAnchor(
              builder: (BuildContext context, MenuController controller,
                      Widget? child) =>
                  InkWell(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(
                          bottom: 2.0), // Add 2px padding at the bottom
                      child: Icon(Icons.hourglass_top, size: 14),
                    ),
                    DurationWidget(duration: priority.budget)
                  ],
                ),
                onTap: () {
                  if (controller.isOpen) {
                    controller.close();
                  } else {
                    controller.open();
                  }
                },
              ),
              menuChildren: [
                for (var m = 0; m <= 120; m += 15)
                  MenuItemButton(
                    onPressed: () {
                      context.read<PrioritiesBloc>().add(PriorityChanged(
                          priority.copyWith(budget: Duration(minutes: m))));
                    },
                    child: m == 0
                        ? const Text('Done')
                        : DurationWidget(duration: Duration(minutes: m)),
                  ),
              ],
            ),
          ],
        ),
      ]),
      subtitle: const LinearProgressIndicator(value: 0.3),
      selected:
          priority.activity?.id == context.watch<NowBloc>().state.selected?.id,
    );
  }
}

class WeekNavigatorWidget extends StatelessWidget {
  const WeekNavigatorWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final week = context.watch<PrioritiesBloc>().state.week;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () {
            context
                .read<PrioritiesBloc>()
                .add(PrioritiesWeekChanged(week.previous()));
          }),
      Text(week.toFriendlyString()),
      IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () {
            context
                .read<PrioritiesBloc>()
                .add(PrioritiesWeekChanged(week.next()));
          }),
    ]);
  }
}

class PrioritiesPage extends StatelessWidget {
  const PrioritiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PrioritiesBloc, PrioritiesState>(
      builder: (context, prioritiesState) => Scaffold(
        appBar: AppBar(title: const WeekNavigatorWidget()),
        floatingActionButton: FloatingActionButton(
          onPressed: () {
            context.push('/new');
          },
          child: const Icon(Icons.add),
        ),
        body: Builder(builder: (BuildContext context) {
          switch (prioritiesState) {
            case PrioritiesLoading _:
              return const CircularProgressIndicator();
            case PrioritiesLoaded _:
              return CachedReorderableListView(
                onReorder: (int oldIndex, int newIndex) async {
                  var previousIndex = newIndex + (newIndex < oldIndex ? -1 : 0);
                  var nextIndex = newIndex + (newIndex < oldIndex ? 0 : 1);
                  Priority? previous;
                  if (previousIndex >= 0) {
                    previous = prioritiesState.priorities[previousIndex];
                  }
                  Priority? next;
                  if (nextIndex < prioritiesState.priorities.length) {
                    next = prioritiesState.priorities[nextIndex];
                  }
                  final budget = prioritiesState.priorities[oldIndex]
                      .copyWith(after: previous, before: next);
                  context.read<PrioritiesBloc>().add(PriorityChanged(budget));
                },
                list: prioritiesState.priorities,
                itemBuilder: (context, priority) {
                  return BlocProvider.value(
                    key: ValueKey(priority.key),
                    value: BlocProvider.of<NowBloc>(context),
                    child: PriorityWidget(priority: priority),
                  );
                },
              );
          }
        }),
      ),
    );
  }
}
