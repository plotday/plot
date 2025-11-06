import 'package:flutter/widgets.dart' hide Action, Actions;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'action.dart';
import 'package:plot/analytics/analytics.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/widget/icon.dart';

class SetActivityFilters extends Action {
  SetActivityFilters({required this.filters, String? title})
    : super(
        title: title ?? _generateTitle(filters),
        subtitle: _generateSubtitle(filters),
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
      );

  final List<Tag> filters;

  static String _generateTitle(List<Tag> filters) {
    if (filters.isEmpty) {
      return 'Clear filters';
    } else if (filters.length == 1) {
      return filters.first.name;
    } else {
      return '${filters.length} tags';
    }
  }

  static String _generateSubtitle(List<Tag> filters) {
    if (filters.isEmpty) {
      return 'Show all activities';
    } else if (filters.length == 1) {
      return 'Show activities with ${filters.first.name}';
    } else {
      final names = filters.map((tag) => tag.name).join(', ');
      return 'Show activities with $names';
    }
  }

  @override
  Future<ActionReturn> run(BuildContext context) async {
    // Try to find PriorityBloc in scope
    try {
      final priorityBloc = context.read<PriorityBloc>();
      priorityBloc.updateFilter(filters);
    } on ProviderNotFoundException {
      // PriorityBloc not in scope, continue
    }

    // Try to find ActivityBloc in scope
    try {
      final activityBloc = context.read<ActivityBloc>();
      activityBloc.updateFilter(filters);
    } on ProviderNotFoundException {
      // ActivityBloc not in scope, continue
    }

    return const ActionDone();
  }
}

class ToggleActivityFilter extends Action {
  ToggleActivityFilter._({required this.tag, super.on})
    : super(
        title: tag.name,
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
        icon: tag.icon,
      );

  factory ToggleActivityFilter(Tag tag, {required BuildContext context}) {
    final isActive = _isTagActive(context, tag);
    return ToggleActivityFilter._(tag: tag, on: isActive);
  }

  final Tag tag;

  static bool? _isTagActive(BuildContext context, Tag tag) {
    // Try to get current filters from ActivityBloc
    try {
      final activityBloc = context.read<ActivityBloc>();
      return activityBloc.state.filter.contains(tag);
    } on ProviderNotFoundException {
      // Try PriorityBloc instead
      try {
        final priorityBloc = context.read<PriorityBloc>();
        return priorityBloc.state.filter.contains(tag);
      } on ProviderNotFoundException {
        // Neither bloc available
        return null;
      }
    }
  }

  @override
  Future<ActionReturn> run(BuildContext context) async {
    // Try to find ActivityBloc in scope
    try {
      final activityBloc = context.read<ActivityBloc>();
      final currentFilters = List<Tag>.from(activityBloc.state.filter);

      if (currentFilters.contains(tag)) {
        // Remove the tag from filters
        currentFilters.remove(tag);
      } else {
        // Add the tag to filters
        currentFilters.add(tag);
      }

      activityBloc.updateFilter(currentFilters);
    } on ProviderNotFoundException {
      // ActivityBloc not in scope, continue
    }

    // Try to find PriorityBloc in scope
    try {
      final priorityBloc = context.read<PriorityBloc>();
      final currentFilters = List<Tag>.from(priorityBloc.state.filter);

      if (currentFilters.contains(tag)) {
        // Remove the tag from filters
        currentFilters.remove(tag);
      } else {
        // Add the tag to filters
        currentFilters.add(tag);
      }

      priorityBloc.updateFilter(currentFilters);
    } on ProviderNotFoundException {
      // PriorityBloc not in scope, continue
    }

    return const ActionDone();
  }
}

class PickFilterAction extends ShowActions {
  PickFilterAction()
    : super(
        title: 'Pick Filter',
        icon: PlotIcon.filter,
        description: 'Select tags to filter activities',
        actions: (context) async {
          final tags = Tag.getAll();
          final actions = tags
              .map((tag) => ToggleActivityFilter(tag, context: context))
              .toList();
          final remove = actions.where((cmd) => cmd.on == true).toList();
          final add = actions.where((cmd) => cmd.on != true).toList();

          return Actions(
            prompt: 'Pick filters',
            groups: [
              StaticActionGroup(title: 'Remove Filter', actions: remove),
              StaticActionGroup(title: 'Add Filter', actions: add),
            ],
          );
        },
      );
}
