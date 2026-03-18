import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/icon.dart';
import 'logging.dart';

class SetActivityFilters extends Command {
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
      return 'Show all threads';
    } else if (filters.length == 1) {
      return 'Show threads with ${filters.first.name}';
    } else {
      final names = filters.map((tag) => tag.name).join(', ');
      return 'Show threads with $names';
    }
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    // Try to find PriorityBloc in scope
    try {
      final priorityBloc = context.read<PriorityBloc>();
      priorityBloc.updateFilter(filters);
    } on ProviderNotFoundException {
      // PriorityBloc not in scope, continue
    }

    // Try to find ThreadBloc in scope
    try {
      final activityBloc = context.read<ThreadBloc>();
      activityBloc.updateFilter(filters);
    } on ProviderNotFoundException {
      // ThreadBloc not in scope, continue
    }

    return const CommandDone();
  }
}

class ToggleActivityFilter extends Command {
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
    // Try to get current filters from ThreadBloc
    try {
      final activityBloc = context.read<ThreadBloc>();
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
  Future<CommandReturn> run(BuildContext context) async {
    // Try to find ThreadBloc in scope
    try {
      final activityBloc = context.read<ThreadBloc>();
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
      // ThreadBloc not in scope, continue
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

    return const CommandDone();
  }
}

/// Toggle a tag filter for notes within an activity
class ToggleNoteFilter extends Command {
  ToggleNoteFilter._({required this.tag, super.on})
    : super(
        title: tag.name,
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
        icon: tag.icon,
      );

  factory ToggleNoteFilter(Tag tag, {required BuildContext context}) {
    final isActive = _isTagActive(context, tag);
    return ToggleNoteFilter._(tag: tag, on: isActive);
  }

  final Tag tag;

  static bool? _isTagActive(BuildContext context, Tag tag) {
    try {
      final activityBloc = context.read<ThreadBloc>();
      return activityBloc.state.filter.contains(tag);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final activityBloc = context.read<ThreadBloc>();
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
      log.warning('ThreadBloc not found in context for ToggleNoteFilter');
    }

    return const CommandDone();
  }
}

class ToggleIconFilter extends Command {
  ToggleIconFilter._({required this.subType, super.on})
    : super(
        title: subType.label,
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
        icon: subType.icon,
      );

  factory ToggleIconFilter(
    ThreadSubType subType, {
    required BuildContext context,
  }) {
    final isActive = _isActive(context, subType);
    return ToggleIconFilter._(subType: subType, on: isActive);
  }

  final ThreadSubType subType;

  static bool? _isActive(BuildContext context, ThreadSubType subType) {
    try {
      final priorityBloc = context.read<PriorityBloc>();
      return priorityBloc.state.iconFilter.contains(subType.value);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final priorityBloc = context.read<PriorityBloc>();
      priorityBloc.updateIconFilter(subType.value);
    } on ProviderNotFoundException {
      // PriorityBloc not in scope
    }
    return const CommandDone();
  }
}

class _AccentWhenOn extends CommandWrapper {
  _AccentWhenOn(super.command)
    : super(
        run: (c, ctx) async {
          await c.run(ctx);
          return const CommandRefresh();
        },
      );

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    final iconData = command.icon;
    if (iconData == null) return null;
    return Icon(
      iconData,
      size: context.theme.iconSizes.base,
      color: command.on == true
          ? context.theme.colors.primary
          : context.theme.plotColors.muted,
    );
  }
}

class PickFilterCommand extends ShowCommands {
  PickFilterCommand({
    required List<Command> Function(BuildContext) filterCommandsBuilder,
  }) : super(
         title: 'Filters',
         icon: PlotIcon.filter,
         commandsBuilder: (context) async {
           final commands = filterCommandsBuilder(context);
           final iconFilters =
               commands.whereType<ToggleIconFilter>().toList();
           final tagFilters =
               commands.whereType<ToggleActivityFilter>().toList();
           final stateFilters = tagFilters
               .where((c) => c.tag == Tag.archived)
               .toList();
           final otherTagFilters = tagFilters
               .where((c) => c.tag != Tag.archived)
               .toList();

           return Commands(
             groups: [
               if (iconFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Thread type',
                   commands: iconFilters.map(_AccentWhenOn.new).toList(),
                 ),
               if (otherTagFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Tags',
                   commands: otherTagFilters.map(_AccentWhenOn.new).toList(),
                 ),
               if (stateFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'State',
                   commands: stateFilters.map(_AccentWhenOn.new).toList(),
                 ),
             ],
           );
         },
       );
}
