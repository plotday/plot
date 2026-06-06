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
import 'package:plot/widget/emoji.dart';
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
        title = '${pt.name} ${typeLabel.toLowerCase()}';
      } else if (pt != null) {
        title = '${pt.name} thread';
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
        title: pt != null ? '${pt.name} thread' : 'Twist',
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

/// Toggle an assignee filter — narrows the feed to threads assigned to a
/// given contact (`thread.assignee_id`). Mirrors [ToggleIconFilter].
class ToggleAssigneeFilter extends Command {
  ToggleAssigneeFilter._({
    required this.assigneeId,
    required this.label,
    super.on,
  }) : super(
         title: label,
         icon: PlotIcon.assignAdd,
         eventObject: EventObject.filter,
         eventAction: EventAction.filtered,
       );

  factory ToggleAssigneeFilter(
    ActorId assigneeId, {
    required String label,
    required BuildContext context,
  }) {
    return ToggleAssigneeFilter._(
      assigneeId: assigneeId,
      label: label,
      on: _isActive(context, assigneeId),
    );
  }

  final ActorId assigneeId;
  final String label;

  static bool? _isActive(BuildContext context, ActorId assigneeId) {
    try {
      return context.read<PriorityBloc>().state.assigneeFilter.contains(
        assigneeId,
      );
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      final bloc = context.read<PriorityBloc>();
      final next = List<ActorId>.from(bloc.state.assigneeFilter);
      if (next.contains(assigneeId)) {
        next.remove(assigneeId);
      } else {
        next.add(assigneeId);
      }
      bloc.updateAssigneeFilter(next);
    } on ProviderNotFoundException {
      // PriorityBloc not in scope
    }
    return const CommandDone();
  }
}

/// Toggle the "Muted" search filter — restricts the feed to threads carrying
/// a `mute_by_thread_id` flag (the ones swept up by a Mute rule) so users can
/// find and un-mute them. Backed by `muteOnly` on [PriorityBloc]; unlike the
/// set-valued tag/reaction/assignee filters this is a standalone boolean.
class ToggleMutedFilter extends Command {
  ToggleMutedFilter._({super.on})
    : super(
        title: 'Muted',
        icon: PlotIcon.volumeSlash,
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
      );

  factory ToggleMutedFilter({required BuildContext context}) {
    return ToggleMutedFilter._(on: _isActive(context));
  }

  static bool? _isActive(BuildContext context) {
    try {
      return context.read<PriorityBloc>().state.muteOnly;
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      context.read<PriorityBloc>().toggleMuteOnly();
    } on ProviderNotFoundException {
      // PriorityBloc not in scope
    }
    return const CommandDone();
  }
}

/// Replace the reaction filter set across whichever bloc is in scope.
class SetReactionFilters extends Command {
  SetReactionFilters({required this.emojis, String? title})
    : super(
        title: title ?? _generateTitle(emojis),
        subtitle: _generateSubtitle(emojis),
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
      );

  final List<Reaction> emojis;

  static String _generateTitle(List<Reaction> emojis) {
    if (emojis.isEmpty) return 'Clear reaction filters';
    if (emojis.length == 1) return emojis.first;
    return '${emojis.length} reactions';
  }

  static String _generateSubtitle(List<Reaction> emojis) {
    if (emojis.isEmpty) return 'Show all threads';
    if (emojis.length == 1) {
      return 'Show threads reacted with ${emojis.first}';
    }
    return 'Show threads reacted with ${emojis.join(' ')}';
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      context.read<PriorityBloc>().updateReactionFilter(emojis);
    } on ProviderNotFoundException {
      // not in scope
    }
    try {
      context.read<ThreadBloc>().updateReactionFilter(emojis);
    } on ProviderNotFoundException {
      // not in scope
    }
    return const CommandDone();
  }
}

/// Toggle a single emoji in the reaction filter for the active bloc(s).
class ToggleReactionFilter extends Command {
  ToggleReactionFilter._({required this.emoji, super.on})
    : super(
        title: emojiDisplayName(emoji),
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
      );

  factory ToggleReactionFilter(
    Reaction emoji, {
    required BuildContext context,
  }) {
    return ToggleReactionFilter._(emoji: emoji, on: _isActive(context, emoji));
  }

  final Reaction emoji;

  static bool? _isActive(BuildContext context, Reaction emoji) {
    try {
      return context.read<ThreadBloc>().state.reactionFilter.contains(emoji);
    } on ProviderNotFoundException {
      try {
        return context
            .read<PriorityBloc>()
            .state
            .reactionFilter
            .contains(emoji);
      } on ProviderNotFoundException {
        return null;
      }
    }
  }

  @override
  Widget? buildIcon(BuildContext context, {bool hoverIcon = false}) {
    return EmojiCommandIcon(emoji);
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    void toggleIn(List<Reaction> current) {
      if (current.contains(emoji)) {
        current.remove(emoji);
      } else {
        current.add(emoji);
      }
    }

    try {
      final bloc = context.read<ThreadBloc>();
      final next = List<Reaction>.from(bloc.state.reactionFilter);
      toggleIn(next);
      bloc.updateReactionFilter(next);
    } on ProviderNotFoundException {
      // not in scope
    }
    try {
      final bloc = context.read<PriorityBloc>();
      final next = List<Reaction>.from(bloc.state.reactionFilter);
      toggleIn(next);
      bloc.updateReactionFilter(next);
    } on ProviderNotFoundException {
      // not in scope
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
           final tagFilters = commands
               .whereType<ToggleActivityFilter>()
               .where((c) => !hiddenTags.contains(c.tag))
               .toList();
           final reactionFilters =
               commands.whereType<ToggleReactionFilter>().toList();
           final assigneeFilters =
               commands.whereType<ToggleAssigneeFilter>().toList();
           final mutedFilters =
               commands.whereType<ToggleMutedFilter>().toList();

           // Split active vs. inactive across all filter types. Active
           // filters collect into a single "Filters" section at the top
           // (mirroring the share picker's "Shared" section). Inactive
           // options stay grouped by type below — Status (Muted), then
           // Thread type, then Tags, then Reactions, then Assignee.
           final activeFilters = <Command>[
             ...mutedFilters.where((c) => c.on == true),
             ...iconFilters.where((c) => c.on == true),
             ...tagFilters.where((c) => c.on == true),
             ...reactionFilters.where((c) => c.on == true),
             ...assigneeFilters.where((c) => c.on == true),
           ];
           final inactiveMutedFilters = mutedFilters
               .where((c) => c.on != true)
               .toList();
           final inactiveIconFilters = iconFilters
               .where((c) => c.on != true)
               .toList();
           final inactiveTagFilters = tagFilters
               .where((c) => c.on != true)
               .toList();
           final inactiveReactionFilters = reactionFilters
               .where((c) => c.on != true)
               .toList();
           final inactiveAssigneeFilters = assigneeFilters
               .where((c) => c.on != true)
               .toList();

           return Commands(
             groups: [
               if (activeFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Filters',
                   commands: activeFilters,
                 ),
               if (inactiveMutedFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Status',
                   commands: inactiveMutedFilters,
                 ),
               if (inactiveIconFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Thread type',
                   commands: inactiveIconFilters,
                 ),
               if (inactiveTagFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Tags',
                   commands: inactiveTagFilters,
                 ),
               if (inactiveReactionFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Reactions',
                   commands: inactiveReactionFilters,
                 ),
               if (inactiveAssigneeFilters.isNotEmpty)
                 StaticCommandGroup(
                   title: 'Assignee',
                   commands: inactiveAssigneeFilters,
                 ),
             ],
           );
         },
       );
}
