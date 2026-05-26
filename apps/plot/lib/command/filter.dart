import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logo_image.dart';
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
  ToggleIconFilter._({
    required this.iconValue,
    required super.title,
    required super.icon,
    this.logoUrl,
    this.logoDarkUrl,
    super.on,
  }) : super(
         eventObject: EventObject.filter,
         eventAction: EventAction.filtered,
       );

  factory ToggleIconFilter(String iconValue, {required BuildContext context}) {
    final info = _describe(iconValue);
    final isActive = _isActive(context, iconValue);
    return ToggleIconFilter._(
      iconValue: iconValue,
      title: info.title,
      icon: info.icon,
      logoUrl: info.logoUrl,
      logoDarkUrl: info.logoDarkUrl,
      on: isActive,
    );
  }

  final String iconValue;
  final String? logoUrl;
  final String? logoDarkUrl;

  /// True when this filter represents a logo-bearing entry (connector link
  /// type or twist) rather than a built-in icon. Used by filter wrappers to
  /// decide whether to render [buildIcon] instead of tinting an [IconData].
  bool get hasLogo => logoUrl != null;

  static ({
    String title,
    IconData? icon,
    String? logoUrl,
    String? logoDarkUrl,
  })
  _describe(String iconValue) {
    // Built-in subtype (action, notes, idea, …)
    final subType = ThreadSubType.fromIcon(iconValue);
    if (subType != null) {
      return (
        title: subType.label,
        icon: subType.icon,
        logoUrl: null,
        logoDarkUrl: null,
      );
    }

    // Connector link type: "connector:<twistId>:<type>"
    if (iconValue.startsWith('connector:')) {
      final parts = iconValue.substring(10).split(':');
      final twistId = BigInt.tryParse(parts[0]);
      final type = parts.length > 1 ? parts[1] : null;
      final pt = twistId != null
          ? TwistInstance.findByTwistId(twistId)
          : null;
      final resolved = Thread.resolveIcon(iconValue);
      String title;
      if (pt != null && type != null) {
        final config =
            pt.parsedLinkTypes?.where((c) => c.type == type).firstOrNull ??
            Channel.findBySource(
              pt.id,
            )?.parsedLinkTypes?.where((c) => c.type == type).firstOrNull;
        final typeLabel = config?.label ?? type;
        title = '${pt.name} $typeLabel';
      } else if (pt != null) {
        title = pt.name;
      } else {
        title = 'Link';
      }
      return (
        title: title,
        icon: resolved.fallbackIcon,
        logoUrl: resolved.logoUrl,
        logoDarkUrl: resolved.logoDarkUrl,
      );
    }

    // Twist-authored thread: "twist:<id>"
    if (iconValue.startsWith('twist:')) {
      final twistId = BigInt.tryParse(iconValue.substring(6));
      final pt = twistId != null
          ? TwistInstance.findByTwistId(twistId)
          : null;
      final resolved = Thread.resolveIcon(iconValue);
      return (
        title: pt?.name ?? 'Twist',
        icon: resolved.fallbackIcon,
        logoUrl: resolved.logoUrl,
        logoDarkUrl: resolved.logoDarkUrl,
      );
    }

    // Direct URL logo
    if (iconValue.startsWith('http')) {
      return (
        title: 'Link',
        icon: PlotIcon.link,
        logoUrl: iconValue,
        logoDarkUrl: null,
      );
    }

    if (iconValue == 'link') {
      return (
        title: 'Link',
        icon: PlotIcon.link,
        logoUrl: null,
        logoDarkUrl: null,
      );
    }

    return (
      title: iconValue,
      icon: PlotIcon.notes,
      logoUrl: null,
      logoDarkUrl: null,
    );
  }

  static bool? _isActive(BuildContext context, String iconValue) {
    try {
      final priorityBloc = context.read<PriorityBloc>();
      return priorityBloc.state.iconFilter.contains(iconValue);
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    if (logoUrl == null) return null;
    final isDark = context.colour.brightness == Brightness.dark;
    final url = isDark ? (logoDarkUrl ?? logoUrl!) : logoUrl!;
    return LogoImage(url: url, size: context.theme.iconSizes.base);
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final priorityBloc = context.read<PriorityBloc>();
      priorityBloc.updateIconFilter(iconValue);
    } on ProviderNotFoundException {
      // PriorityBloc not in scope
    }
    return const CommandDone();
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
           // Filter tag commands. Hide:
           //   - Tag.archived — archived visibility is toggled from the
           //     header menu, not the search filter modal.
           //   - Tag.todo / Tag.unread — thread-level state filters that
           //     no longer surface in the search modal (the unified feed
           //     already separates Updates / Doing / Activity).
           const hiddenTags = {Tag.archived, Tag.todo, Tag.unread};
           const listTags = {Tag.task, Tag.reading};
           final tagFilters = commands
               .whereType<ToggleActivityFilter>()
               .where((c) => !hiddenTags.contains(c.tag))
               .toList();
           final listFilters = tagFilters
               .where((c) => listTags.contains(c.tag))
               .toList();
           final otherTagFilters = tagFilters
               .where((c) => !listTags.contains(c.tag))
               .toList();

           // Split active vs. inactive across all filter types. Active
           // filters collect into a single "Filters" section at the top
           // (mirroring the share picker's "Shared" section). Inactive
           // options stay grouped by type below — Lists first, then
           // Thread type, then Tags.
           final activeFilters = <Command>[
             ...iconFilters.where((c) => c.on == true),
             ...tagFilters.where((c) => c.on == true),
           ];
           final inactiveListFilters = listFilters
               .where((c) => c.on != true)
               .toList();
           final inactiveIconFilters = iconFilters
               .where((c) => c.on != true)
               .toList();
           final inactiveOtherTagFilters = otherTagFilters
               .where((c) => c.on != true)
               .toList();

           return Commands(
             groups: [
               if (activeFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Filters',
                   commands: activeFilters,
                 ),
               if (inactiveListFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Lists',
                   commands: inactiveListFilters,
                 ),
               if (inactiveIconFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Thread type',
                   commands: inactiveIconFilters,
                 ),
               if (inactiveOtherTagFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Tags',
                   commands: inactiveOtherTagFilters,
                 ),
             ],
           );
         },
       );
}
