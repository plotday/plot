import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/theme.dart' show ThemeBloc;

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/store/store.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/url_title.dart' show fetchUrlMetadata;
import 'package:plot/analytics/tracker.dart';
import 'logging.dart';

/// Tracks hover state and rebuilds its child via [builder]. Used to apply
/// a "very muted until hovered" effect to unselected chips.
class _HoverBuilder extends StatefulWidget {
  const _HoverBuilder({required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<_HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

@RoutePage(name: "NewThreadWrapperRoute")
class NewThreadWrapper implements AutoRouteWrapper {
  const NewThreadWrapper();

  @override
  Widget wrappedRoute(BuildContext context) {
    return AutoRouter(placeholder: (context) => const LoadingPage());
  }
}

@RoutePage()
class NewThreadPage extends StatefulWidget {
  const NewThreadPage({
    super.key,
    @QueryParam('startTime') this.startTime,
    @QueryParam('endTime') this.endTime,
    @QueryParam('duration') this.duration,
    @QueryParam('priorityId') this.priorityId,
    @QueryParam('sharedUrl') this.sharedUrl,
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;
  final String? sharedUrl;

  @override
  State<NewThreadPage> createState() => NewThreadPageState();
}

class NewThreadPageState extends State<NewThreadPage> {
  final GlobalKey<NoteEditorState> _threadEditorKey =
      GlobalKey<NoteEditorState>();
  final GlobalKey<InlineTitleInputState> _titleInputKey =
      GlobalKey<InlineTitleInputState>();

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;
  ThreadHeaderNotifier? _headerNotifier;
  // Cached so callbacks triggered during deactivate() (e.g. NoteEditor
  // saving its draft) don't call context.read once ancestors are detached.
  PriorityBloc? _priorityBloc;
  bool _hasAppliedQueryParams = false;

  /// People + groups the user has recently shared threads with, ordered by
  /// the same MRU sort the share modal uses. Drives the suggestion chips.
  List<ShareCandidate> _recentCandidates = const [];

  /// Selected actors pinned in the "with" chip row. Only updated when the
  /// modal changes contacts — tapping a chip toggles selected state without
  /// removing the chip, so the row stays stable.
  List<Actor> _pinnedActors = const [];

  /// Pinned email invites shown in the chip row. Same stability rule.
  List<String> _pinnedEmails = const [];

  /// Selected groups pinned in the chip row (from per-priority defaults, or
  /// added via the share picker). Users can toggle them off on the draft.
  List<GroupRow> _pinnedGroups = const [];

  /// MRU-ordered suggestion chips appended after the selected groups,
  /// actors, and emails. Mixes [ActorShareCandidate] and
  /// [GroupShareCandidate] so a recently-used group can sit beside
  /// recently-used contacts instead of always coming first.
  List<ShareCandidate> _pinnedSuggestions = const [];

  /// All available create-targets for this user, loaded once on mount and
  /// rerun when the priority changes (so MRU rerank reflects the new
  /// priority).
  List<CreateTarget> _allConnectionTargets = const [];

  /// The 3 chips shown in the connection row, ranked per-priority then
  /// global by [LocalPreferencesBloc.rankConnectionsByMru].
  List<CreateTarget> _pinnedConnections = const [];

  // Selected twist for chat mode
  TwistInstance? _selectedTwist;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Save the provider reference
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _priorityBloc = context.read<PriorityBloc>();
    // Register with ThreadHeaderNotifier so unified header knows NewThreadPage is visible
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
    // We've arrived — clear the navigation-intent flag set by callers
    // like the bottom-nav "New" button (priorities_shell._openNewThread).
    if (ThreadHeaderNotifier.pendingNewThreadIntent.value) {
      ThreadHeaderNotifier.pendingNewThreadIntent.value = false;
    }
    // Prefer middle panel on resize while NewThreadPage is visible
    context.read<LayoutBloc>().preferMiddle = true;
    // Register ThreadEditor with the focus coordination provider
    // Both registrations deferred to avoid notifyListeners() during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _headerNotifier?.register(
        onSearchChanged: (_) {},
        onSearchClosed: () {},
        tags: const [],
        filter: const [],
        isNewThread: true,
      );
      _provider?.registerActivityPanel(
        editorFocusCallback: () => _threadEditorKey.currentState?.focus(),
      );
    });

    // Apply query parameters to draft
    if (!_hasAppliedQueryParams) {
      _hasAppliedQueryParams = true;
      _initializeDraft();
    }
  }

  /// Adds the current draft to [ThreadsBase.autoFileIds] when the user is in
  /// the root context and hasn't explicitly picked or remembered a priority.
  /// Wraps the static-set mutation in setState so the priority chip rebuilds.
  void _applyDefaultAutoFile() {
    final bloc = context.read<PriorityBloc>();
    final hasExplicitPriority =
        widget.priorityId != null || bloc.newThreadDefaultPriority != null;
    if (bloc.state.context.root && !hasExplicitPriority) {
      final draftId = bloc.state.draft.id.toString();
      if (ThreadsBase.autoFileIds.add(draftId)) {
        setState(() {});
      }
    }
  }

  /// Sequences query parameter application and post-load setup.
  /// Async because _applyQueryParametersToDraft awaits DB lookups.
  Future<void> _initializeDraft() async {
    await _applyQueryParametersToDraft();
    if (!mounted) return;

    // Auto-organize is ON by default only in the root ("Everything") priority
    // context and when the user has not explicitly picked or carried over a
    // priority. In a non-root context, the default is the most recent picker
    // priority (session-remembered) or the current context priority — never
    // auto — so the thread goes where the user is working.
    _applyDefaultAutoFile();

    // Load recently shared people + groups for suggestion chips.
    await _loadRecentCandidates();
    if (!mounted) return;
    // Load available connection create-targets for the connection chip row.
    await _loadConnections();
  }

  Future<void> _loadConnections() async {
    try {
      final targets = await loadCreateTargets();
      if (!mounted) return;
      setState(() {
        _allConnectionTargets = targets;
        _pinnedConnections = _rankConnections(targets);
      });
    } catch (e, t) {
      log.warning('[NewThreadPage._loadConnections] failed', e, t);
      Tracker.captureException(e, t);
    }
  }

  void _refreshPinnedConnections() {
    setState(() {
      _pinnedConnections = _rankConnections(_allConnectionTargets);
    });
  }

  /// Pure helper that ranks [targets] using the per-priority MRU and returns
  /// the top 3 chips to pin. Returns an empty list if [targets] is empty so
  /// the chip row collapses cleanly.
  List<CreateTarget> _rankConnections(List<CreateTarget> targets) {
    if (targets.isEmpty) return const [];
    final bloc = context.read<PriorityBloc>();
    final priorityId = bloc.state.draft.priority.id.toString();
    final prefs = context.read<LocalPreferencesBloc>();
    final keys = targets.map((t) => t.key).toList();
    final ranked = prefs.rankConnectionsByMru(
      keys: keys,
      priorityId: priorityId,
    );
    final byKey = {for (final t in targets) t.key: t};
    return ranked.take(3).map((k) => byKey[k]!).toList(growable: false);
  }

  Future<void> _applyQueryParametersToDraft() async {
    final bloc = context.read<PriorityBloc>();

    // Parse query parameters
    DateTime? queryStartTime;
    DateTime? queryEndTime;
    Priority? queryPriority;

    if (widget.startTime != null) {
      try {
        queryStartTime = DateTime.parse(widget.startTime!);
      } catch (e) {
        log.warning('[NewThreadPage] Failed to parse startTime', e);
      }
    }

    if (widget.endTime != null) {
      try {
        queryEndTime = DateTime.parse(widget.endTime!);
      } catch (e) {
        log.warning('[NewThreadPage] Failed to parse endTime', e);
      }
    }

    // If startTime is provided but endTime is not, calculate from duration
    if (queryStartTime != null && queryEndTime == null) {
      final durationMinutes = widget.duration ?? 60; // Default to 1 hour
      queryEndTime = queryStartTime.add(Duration(minutes: durationMinutes));
    }

    if (widget.priorityId != null) {
      try {
        final priorityId = Uuid.fromShortString(widget.priorityId!);
        queryPriority = await Priority.getOne(priorityId);
      } catch (e) {
        log.warning('[NewThreadPage] Failed to parse priorityId', e);
      }
    }

    // Apply remembered default priority if no query priority was provided
    if (queryPriority == null && bloc.newThreadDefaultPriority != null) {
      final remembered = bloc.newThreadDefaultPriority!;
      if (remembered.id != bloc.state.draft.priority.id) {
        queryPriority = remembered;
      }
    }

    if (!mounted) return;

    // Apply to draft if any query parameters were provided
    // Re-read bloc.state.draft after awaits to avoid overwriting concurrent changes
    if (queryStartTime != null || queryPriority != null) {
      Thread updatedDraft;
      if (queryStartTime != null && queryEndTime != null) {
        // StartTime takes precedence - create a scheduled activity
        updatedDraft = bloc.state.draft.copyWith(
          at: Value(DateTimeRange(queryStartTime, queryEndTime)),
          priority: queryPriority ?? bloc.state.draft.priority,
          draft: true,
        );
        await bloc.updateDraft(updatedDraft);
      } else if (queryPriority != null) {
        updatedDraft = bloc.state.draft.copyWith(
          priority: queryPriority,
          draft: true,
        );
        await bloc.updateDraft(updatedDraft);
      }
    }

    // Share intent: add the shared URL as a link action on the draft note.
    if (widget.sharedUrl != null && mounted) {
      final currentNote = bloc.state.draftNote;
      final existingActions = currentNote.actions ?? const <UserAction>[];
      final alreadyPresent = existingActions.any(
        (a) => a is ExternalUserAction && a.url == widget.sharedUrl,
      );
      if (!alreadyPresent) {
        log.info('[NewThreadPage] Adding shared URL as ExternalUserAction');
        final updatedNote = currentNote.copyWith(
          actions: [
            ...existingActions,
            ExternalUserAction(
              title: widget.sharedUrl!,
              url: widget.sharedUrl!,
            ),
          ],
        );
        await bloc.updateDraft(bloc.state.draft, note: updatedNote);
        // Fire-and-forget metadata fetch — when it returns we replace the
        // action so the link chip shows the page title and the thread
        // (created via AddThreadWithLink on submit) gets the favicon.
        unawaited(_resolveSharedUrlMetadata(widget.sharedUrl!));
      }
    }
  }

  /// Looks up `<title>` and favicon for [url] and updates the matching
  /// `ExternalUserAction` in the draft. Matches by URL — the draft note may
  /// have been mutated while the request was in flight, so identity isn't
  /// safe.
  Future<void> _resolveSharedUrlMetadata(String url) async {
    final meta = await fetchUrlMetadata(url);
    if (!mounted) return;
    if (meta.title == null && meta.favicon == null) return;
    final bloc = _priorityBloc;
    if (bloc == null) return;
    final note = bloc.state.draftNote;
    final actions = note.actions ?? const <UserAction>[];
    final idx = actions.indexWhere(
      (a) => a is ExternalUserAction && a.url == url,
    );
    if (idx < 0) return;
    final existing = actions[idx] as ExternalUserAction;
    // If the user already typed a custom title or the metadata didn't
    // upgrade either field, don't overwrite.
    final shouldUpdateTitle = meta.title != null && existing.title == url;
    final shouldUpdateFavicon =
        meta.favicon != null && existing.favicon == null;
    if (!shouldUpdateTitle && !shouldUpdateFavicon) return;
    final replacement = ExternalUserAction(
      title: shouldUpdateTitle ? meta.title! : existing.title,
      url: existing.url,
      favicon: shouldUpdateFavicon ? meta.favicon : existing.favicon,
    );
    final next = [...actions]..[idx] = replacement;
    await bloc.updateDraft(
      bloc.state.draft,
      note: note.copyWith(actions: next),
    );
  }

  @override
  void dispose() {
    // Unregister from the focus coordination provider using saved reference
    _provider?.unregisterActivityPanel();
    // Unregister from thread header notifier
    _headerNotifier?.unregister();
    // Clear middle panel preference when leaving NewThreadPage
    LayoutBloc.instance?.preferMiddle = false;
    super.dispose();
  }

  /// Loads people + groups for the "with" suggestion chips, sorted by the
  /// shared MRU pass in [Actor.getSortedShareCandidates] so a recently-used
  /// group can interleave with recently-used contacts. Scoped to the
  /// draft's currently selected priority so suggestions reflect who the
  /// user typically shares with there, falling back to cross-priority MRU
  /// for candidates with no history in this priority.
  Future<void> _loadRecentCandidates() async {
    try {
      final priority = context.read<PriorityBloc>().state.draft.priority;
      final sorted = await Actor.getSortedShareCandidates(priority: priority);
      final recent = sorted.take(10).toList();
      if (mounted) {
        setState(() => _recentCandidates = recent);
        _refreshPinnedChips();
      }
    } catch (e, t) {
      log.warning('[NewThreadPage._loadRecentCandidates] failed', e, t);
    }
  }

  /// Rebuilds the pinned chip list from current draft state + recent contacts.
  /// Call after modal changes or initial load — NOT after chip taps.
  Future<void> _refreshPinnedChips() async {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    final selfUuids = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    // Drop any contact linked to the current user — it can sneak into
    // draft.contacts via inherited priority defaults or stale data. The
    // user is implicitly part of every thread they author, so showing a
    // self chip is always wrong.
    final selectedIds = draft.contacts
        .where((id) => !selfUuids.contains(id))
        .toSet();
    final pendingEmails = draft.inviteEmails;
    final groupIds = draft.groups;

    // Resolve selected contacts to actors.
    // Note: If an actor isn't in cache, it's skipped here. _handleDraftChanged
    // fetches missing actors before calling this to ensure immediate display.
    final selected = selectedIds
        .map((id) => Actor.fromCache(ActorId.fromUuid(id)))
        .where((a) => a != null)
        .cast<Actor>()
        .toList();

    // Resolve attached groups. Keep order from the draft so chips stay stable
    // as toggles change which ones are selected.
    final groups = <GroupRow>[];
    for (final id in groupIds) {
      final g = await Group.getOne(id);
      if (g != null) groups.add(g);
    }

    // Budget: 3 total chips across selected groups + contacts + emails +
    // suggestions. Selected items always win the leading slots so a
    // newly-attached chip never gets bumped by a suggestion.
    final groupChipCount = groups.length.clamp(0, 3);
    final selectedChipCount = selected.length.clamp(0, 3 - groupChipCount);
    final emailSlots = (3 - groupChipCount - selectedChipCount).clamp(0, 3);
    final emailChipCount = pendingEmails.length.clamp(0, emailSlots);
    final suggestionSlots =
        (3 - groupChipCount - selectedChipCount - emailChipCount).clamp(0, 3);

    // Pull from the merged MRU list so a recently-used group and a
    // recently-used contact compete for the same suggestion slot.
    final suggestions = <ShareCandidate>[];
    for (final candidate in _recentCandidates) {
      if (suggestions.length >= suggestionSlots) break;
      switch (candidate) {
        case ActorShareCandidate(:final actor):
          final id = actor.id.toUuid();
          if (selectedIds.contains(id) || selfUuids.contains(id)) continue;
          suggestions.add(candidate);
        case GroupShareCandidate(:final group):
          if (groupIds.contains(group.id)) continue;
          suggestions.add(candidate);
      }
    }

    if (!mounted) return;
    setState(() {
      _pinnedGroups = groups.take(groupChipCount).toList();
      _pinnedActors = selected.take(selectedChipCount).toList();
      _pinnedEmails = pendingEmails.take(emailChipCount).toList();
      _pinnedSuggestions = suggestions;
    });
  }

  Widget _buildThreadTypeSelector(BuildContext context, PriorityState state) {
    final connectionRow = _buildConnectionRow(context, state);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPriorityChipRow(context, state),
        if (connectionRow != null) ...[
          SizedBox(height: context.theme.spacing.md),
          connectionRow,
        ],
        SizedBox(height: context.theme.spacing.md),
        _buildWithSelector(context, state),
        SizedBox(height: context.theme.spacing.md),
        _buildTitleRow(context, state),
      ],
    );
  }

  Widget _buildTitleRow(BuildContext context, PriorityState state) {
    return InlineTitleInput(
      key: _titleInputKey,
      title: state.draft.title,
      onChanged: (next) async {
        final bloc = _priorityBloc;
        if (bloc == null) return;
        try {
          await bloc.updateDraft(
            bloc.state.draft.copyWith(title: Value(next)),
          );
        } catch (e, t) {
          Tracker.captureException(e, t);
        }
      },
    );
  }

  /// Row of connection chips. Each chip toggles a [CreateLinkUserAction] on
  /// the draft note (single-select: tapping a different chip replaces the
  /// previous one). Hidden when the user has no enabled connections that
  /// expose a create-default link type.
  Widget? _buildConnectionRow(BuildContext context, PriorityState state) {
    if (_allConnectionTargets.isEmpty) return null;
    final hasMore = _allConnectionTargets.length > _pinnedConnections.length;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final target in _pinnedConnections)
          ConnectionChip(
            target: target,
            selected: _isConnectionActive(target),
            onTap: () => _toggleConnection(target),
          ),
        Button.icon(
          _ConnectionPickerCommand(
            onOpen: _openConnectionPicker,
            hasMore: hasMore,
          ),
        ),
      ],
    );
  }

  /// Row containing the priority picker chip. In non-root contexts when the
  /// thread is not already in Auto mode, a leading veryMuted sparkles icon
  /// is shown that toggles the priority to Auto.
  Widget _buildPriorityChipRow(BuildContext context, PriorityState state) {
    final draftIdStr = state.draft.id.toString();
    final auto = ThreadsBase.autoFileIds.contains(draftIdStr);
    final showLeadingSparkles = !state.context.root && !auto;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 8,
      children: [
        if (showLeadingSparkles) _buildAutoSparklesToggle(context),
        _buildPriorityChip(context, state, auto: auto),
      ],
    );
  }

  Widget _buildAutoSparklesToggle(BuildContext context) {
    final fontSize = context.theme.typography.sm.fontSize;
    final button = FButton(
      onPress: _switchToAuto,
      variant: FButtonVariant.ghost,
      style: FButtonStyleDelta.delta(
        contentStyle: FButtonContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(
            EdgeInsets.symmetric(
              horizontal: 6,
              vertical: isMobilePlatform() ? 10 : 6,
            ),
          ),
        ),
      ),
      mainAxisSize: MainAxisSize.min,
      child: Icon(
        PlotIcon.sparkles,
        size: fontSize,
        color: context.theme.plotColors.veryMuted,
      ),
    );
    if (!hasPhysicalKeyboard()) return button;
    return FTooltip(
      tipBuilder: (context, controller) => const Text('Auto organize'),
      child: button,
    );
  }

  /// Tooltip shown on the priority/title/type chips. Shows the label on one
  /// line and the platform-formatted shortcut below it when a physical
  /// keyboard is available.
  Widget _buildChipTooltip({
    required BuildContext context,
    required String label,
    required ShortcutActivator shortcut,
  }) {
    final shortcutText = formatShortcut(shortcut);
    if (shortcutText.isEmpty) return Text(label);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Text(
          shortcutText,
          style: context.theme.typography.xs.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
      ],
    );
  }

  Widget _buildPriorityChip(
    BuildContext context,
    PriorityState state, {
    required bool auto,
  }) {
    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 12,
      vertical: isMobilePlatform() ? 10 : 6,
    );
    final styleDelta = FButtonStyleDelta.delta(
      decoration: FVariantsDelta.delta([
        FVariantOperation.all(
          DecorationDelta.boxDelta(borderRadius: chipRadius),
        ),
      ]),
      contentStyle: FButtonContentStyleDelta.delta(
        padding: EdgeInsetsGeometryDelta.value(chipPadding),
      ),
    );

    final labelStyle = context.theme.typography.sm.copyWith(height: 1);
    final Widget label = auto
        ? Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              Icon(PlotIcon.sparkles, size: labelStyle.fontSize),
              Text('Auto', style: labelStyle),
            ],
          )
        : PriorityLabel(
            priority: state.draft.priority,
            fontSize: labelStyle.fontSize,
            height: 1,
          );

    final button = FButton(
      onPress: () => _selectPriority(context, state),
      variant: FButtonVariant.secondary,
      style: styleDelta,
      mainAxisSize: MainAxisSize.min,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: label,
          ),
          Icon(
            PlotIcon.verticalExpand,
            size: context.theme.iconSizes.xs,
            color: context.theme.plotColors.muted,
          ),
        ],
      ),
    );
    if (!hasPhysicalKeyboard()) return button;
    return FTooltip(
      tipBuilder: (context, controller) => _buildChipTooltip(
        context: context,
        label: 'Change priority',
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.keyP,
          shift: true,
          alt: kIsWeb,
        ),
      ),
      child: button,
    );
  }

  Future<void> _selectPriority(
    BuildContext context,
    PriorityState state,
  ) async {
    final result = await SelectModal.open<Priority>(
      context,
      items: (search) async {
        final priorities = await Priority.get(order: PriorityOrder.nested);
        return [SelectGroup(title: null, items: priorities)];
      },
      itemBuilder: (priority, _) =>
          ListTile(body: PriorityLabel(priority: priority)),
      selectedValue: state.draft.priority,
      prompt: 'Select priority',
      onAdd: (ctx) => createPriorityInline(ctx, parent: state.draft.priority),
      filter: (priority, search) => priority.matchesSearch(search),
    );
    if (!result.present) return;
    final picked = result.value;
    if (!mounted) return;
    await _switchToPriority(picked);
  }

  Future<void> _switchToAuto() async {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    setState(() {
      ThreadsBase.autoFileIds.add(draft.id.toString());
    });
    // Auto-filed threads live in the root priority until the server re-files.
    final root = await Priority.getDefault();
    if (!mounted) return;
    if (draft.priority.id != root.id) {
      final updated = _applyChainDefaults(draft, root);
      await bloc.updateDraft(updated);
    }
    if (mounted) {
      _loadRecentCandidates();
      _refreshPinnedChips();
      _refreshPinnedConnections();
    }
  }

  Future<void> _switchToPriority(Priority priority) async {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    setState(() {
      ThreadsBase.autoFileIds.remove(draft.id.toString());
    });
    if (priority.id != draft.priority.id) {
      final updated = _applyChainDefaults(draft, priority);
      await bloc.updateDraft(updated);
    }
    bloc.setNewThreadDefaultPriority(priority);
    if (mounted) {
      _loadRecentCandidates();
      _refreshPinnedChips();
      _refreshPinnedConnections();
    }
  }

  /// Swap the draft's priority and merge in the new chain's default
  /// contacts/groups/invite-emails. Treats members of the OLD priority
  /// chain's defaults that are still on the draft as seeded (drops them),
  /// keeps everything else as user-added, then unions in the NEW chain's
  /// defaults. See C2 merge semantics in the design.
  Thread _applyChainDefaults(Thread draft, Priority newPriority) {
    final oldPriority = draft.priority;
    final oldContactDefaults = oldPriority.inheritedDefaultSharedContacts
        .toSet();
    final oldGroupDefaults = oldPriority.inheritedDefaultSharedGroups.toSet();
    final oldEmailDefaults = oldPriority.inheritedDefaultSharedInviteEmails
        .toSet();

    final newContactDefaults = newPriority.inheritedDefaultSharedContacts;
    final newGroupDefaults = newPriority.inheritedDefaultSharedGroups;
    final newEmailDefaults = newPriority.inheritedDefaultSharedInviteEmails;

    List<T> merge<T>(List<T> current, Set<T> oldDefaults, List<T> newDefaults) {
      final userAdded = current.where((e) => !oldDefaults.contains(e)).toList();
      final seen = <T>{...userAdded};
      final result = [...userAdded];
      for (final e in newDefaults) {
        if (seen.add(e)) result.add(e);
      }
      return result;
    }

    final mergedContacts = merge(
      draft.contacts,
      oldContactDefaults,
      newContactDefaults,
    );
    final mergedGroups = merge(
      draft.groups,
      oldGroupDefaults,
      newGroupDefaults,
    );
    final mergedEmails = merge(
      draft.inviteEmails,
      oldEmailDefaults,
      newEmailDefaults,
    );

    return draft.copyWith(
      priority: newPriority,
      contacts: Value(mergedContacts.isEmpty ? null : mergedContacts),
      groups: Value(mergedGroups.isEmpty ? null : mergedGroups),
      inviteEmails: Value(mergedEmails.isEmpty ? null : mergedEmails),
    );
  }

  /// Build the "With" chip row: the current user can tap recent contacts
  /// to add or remove them from the thread, or tap the `+` button to open
  /// a searchable picker modal. Selected contacts flow into
  /// `state.draft.contacts`. Up to 3 chips are shown (selected actors +
  /// pending email invites + recent suggestions), plus a more/add button.
  Widget _buildWithSelector(BuildContext context, PriorityState state) {
    // Self contacts are excluded from the chip row entirely (see
    // [_refreshPinnedChips]), so exclude them here too — otherwise hasMore
    // counts an invisible chip and the +more button shows incorrectly.
    final selfUuids = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    final selectedIds = state.draft.contacts
        .where((id) => !selfUuids.contains(id))
        .toSet();
    final pendingEmails = state.draft.inviteEmails.toSet();

    // Render from pinned lists so chips stay stable when toggled via tap.
    // _pinnedGroups, _pinnedActors, _pinnedEmails, and _pinnedSuggestions
    // are only updated by _refreshPinnedChips (called after modal changes
    // and initial load).
    final groupIds = state.draft.groups.toSet();
    final hasMore =
        selectedIds.length > _pinnedActors.length ||
        pendingEmails.length > _pinnedEmails.length ||
        groupIds.length > _pinnedGroups.length;
    final isPrivate =
        selectedIds.isEmpty && groupIds.isEmpty && pendingEmails.isEmpty;

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildLockChip(context, isPrivate: isPrivate),
        for (final group in _pinnedGroups)
          _buildGroupChip(
            context,
            group,
            selected: groupIds.contains(group.id),
          ),
        for (final actor in _pinnedActors)
          _buildContactChip(
            context,
            actor,
            selected: selectedIds.contains(actor.id.toUuid()),
          ),
        for (final email in _pinnedEmails)
          _buildEmailChip(
            context,
            email,
            selected: pendingEmails.contains(email),
          ),
        for (final suggestion in _pinnedSuggestions)
          switch (suggestion) {
            ActorShareCandidate(:final actor) => _buildContactChip(
              context,
              actor,
              selected: selectedIds.contains(actor.id.toUuid()),
            ),
            GroupShareCandidate(:final group) => _buildGroupChip(
              context,
              group,
              selected: groupIds.contains(group.id),
            ),
          },
        _buildAddContactChip(context, state, hasMore: hasMore),
      ],
    );
  }

  Widget _buildGroupChip(
    BuildContext context,
    GroupRow group, {
    required bool selected,
  }) {
    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 10,
      vertical: isMobilePlatform() ? 10 : 5,
    );
    Widget buildChip(bool hovered) {
      return FButton(
        onPress: () => _toggleWithGroup(group),
        variant: selected ? FButtonVariant.primary : FButtonVariant.secondary,
        style: FButtonStyleDelta.delta(
          decoration: FVariantsDelta.delta([
            FVariantOperation.all(
              DecorationDelta.boxDelta(borderRadius: chipRadius),
            ),
          ]),
          contentStyle: FButtonContentStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(chipPadding),
          ),
        ),
        mainAxisSize: MainAxisSize.min,
        prefix: FaIcon(
          FontAwesomeIcons.userGroup,
          size: context.theme.iconSizes.sm,
        ),
        child: Text(
          group.name,
          style: (!selected && !hovered)
              ? TextStyle(color: context.theme.plotColors.veryMuted)
              : null,
        ),
      );
    }

    if (selected) return buildChip(false);
    return _HoverBuilder(builder: (context, hovered) => buildChip(hovered));
  }

  Future<void> _toggleWithGroup(GroupRow group) async {
    final bloc = context.read<PriorityBloc>();
    final current = bloc.state.draft.groups.toList();
    if (current.contains(group.id)) {
      current.remove(group.id);
    } else {
      current.add(group.id);
    }
    await bloc.updateDraft(
      bloc.state.draft.copyWith(
        groups: Value(current.isEmpty ? null : current),
      ),
    );
  }

  Widget _buildLockChip(BuildContext context, {required bool isPrivate}) {
    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 10,
      vertical: isMobilePlatform() ? 10 : 5,
    );

    Widget buildChip(bool hovered) {
      return FButton(
        onPress: isPrivate ? () {} : _clearShareTargets,
        variant: isPrivate ? FButtonVariant.primary : FButtonVariant.secondary,
        style: FButtonStyleDelta.delta(
          decoration: FVariantsDelta.delta([
            FVariantOperation.all(
              DecorationDelta.boxDelta(borderRadius: chipRadius),
            ),
          ]),
          contentStyle: FButtonContentStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(chipPadding),
          ),
        ),
        mainAxisSize: MainAxisSize.min,
        child: FaIcon(
          FontAwesomeIcons.lock,
          size: context.theme.iconSizes.sm,
          color: (isPrivate || hovered)
              ? null
              : context.theme.plotColors.veryMuted,
        ),
      );
    }

    final chip = isPrivate
        ? buildChip(false)
        : _HoverBuilder(builder: (context, hovered) => buildChip(hovered));

    if (!hasPhysicalKeyboard()) return chip;
    return FTooltip(
      tipBuilder: (context, controller) =>
          Text(isPrivate ? 'Private' : 'Make private'),
      child: chip,
    );
  }

  Future<void> _clearShareTargets() async {
    final bloc = _priorityBloc;
    if (bloc == null) return;
    await bloc.updateDraft(
      bloc.state.draft.copyWith(
        contacts: const Value(null),
        groups: const Value(null),
        inviteEmails: const Value(null),
      ),
    );
  }

  Widget _buildContactChip(
    BuildContext context,
    Actor actor, {
    required bool selected,
  }) {
    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 10,
      vertical: isMobilePlatform() ? 10 : 5,
    );
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    Widget buildChip(bool hovered) {
      return FButton(
        onPress: () => _toggleWithContact(actor),
        variant: selected ? FButtonVariant.primary : FButtonVariant.secondary,
        style: FButtonStyleDelta.delta(
          decoration: FVariantsDelta.delta([
            FVariantOperation.all(
              DecorationDelta.boxDelta(borderRadius: chipRadius),
            ),
          ]),
          contentStyle: FButtonContentStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(chipPadding),
          ),
        ),
        mainAxisSize: MainAxisSize.min,
        prefix: Opacity(
          opacity: selected || hovered ? 1.0 : (isDark ? 0.5 : 0.9),
          child: Avatar(
            actor: actor,
            size: context.theme.iconSizes.sm,
            tooltip: false,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            actor.name ?? actor.email ?? 'Unknown',
            overflow: TextOverflow.ellipsis,
            style: (!selected && !hovered)
                ? TextStyle(color: context.theme.plotColors.veryMuted)
                : null,
          ),
        ),
      );
    }

    final email = actor.email;
    final showEmailTooltip = email != null && actor.name != null;
    Widget chip = selected
        ? buildChip(false)
        : _HoverBuilder(builder: (context, hovered) => buildChip(hovered));
    if (showEmailTooltip) {
      chip = FTooltip(
        tipBuilder: (context, controller) => Text(email),
        child: chip,
      );
    }
    return chip;
  }

  Widget _buildEmailChip(
    BuildContext context,
    String email, {
    bool selected = true,
  }) {
    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 10,
      vertical: isMobilePlatform() ? 10 : 5,
    );
    return FTooltip(
      tipBuilder: (context, controller) => Text(email),
      child: FButton(
        onPress: () => _toggleEmailInvite(email),
        variant: selected ? FButtonVariant.primary : FButtonVariant.secondary,
        style: FButtonStyleDelta.delta(
          decoration: FVariantsDelta.delta([
            FVariantOperation.all(
              DecorationDelta.boxDelta(borderRadius: chipRadius),
            ),
          ]),
          contentStyle: FButtonContentStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(chipPadding),
          ),
        ),
        mainAxisSize: MainAxisSize.min,
        prefix: FaIcon(
          FontAwesomeIcons.envelope,
          size: context.theme.iconSizes.sm,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(email, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }

  Widget _buildAddContactChip(
    BuildContext context,
    PriorityState state, {
    required bool hasMore,
  }) {
    return Button.icon(
      _ShareNewThread(
        onOpen: () => _openSharedPicker(context),
        hasMore: hasMore,
      ),
    );
  }

  CreateLinkUserAction? get _activeCreateAction {
    final note = _priorityBloc?.state.draftNote;
    return note?.actions?.whereType<CreateLinkUserAction>().firstOrNull;
  }

  bool _isConnectionActive(CreateTarget target) {
    final active = _activeCreateAction;
    if (active == null) return false;
    return active.twistInstanceId == target.twist.id.toString() &&
        active.channelId == target.channel.channelId &&
        active.linkType == target.linkType.type;
  }

  Future<void> _toggleConnection(CreateTarget target) async {
    // Use the cached bloc: _openConnectionPicker awaits the modal before
    // calling us, so context.read could read from a stale tree.
    final bloc = _priorityBloc;
    if (bloc == null) return;
    final note = bloc.state.draftNote;
    final actions = List<UserAction>.from(note.actions ?? const []);
    final wasActive = _isConnectionActive(target);
    actions.removeWhere((a) => a is CreateLinkUserAction);
    if (!wasActive) {
      actions.add(target.toUserAction());
    }
    await bloc.updateDraft(
      bloc.state.draft,
      note: note.copyWith(actions: actions.isEmpty ? null : actions),
    );
  }

  Future<void> _openConnectionPicker() async {
    final picked = await ConnectionPickerModal.open(context);
    if (picked == null || !mounted) return;
    await _toggleConnection(picked);
  }

  Future<void> _toggleWithContact(Actor actor) async {
    final bloc = context.read<PriorityBloc>();
    final current = bloc.state.draft.contacts.toList();
    final contactUuid = actor.id.toUuid();
    if (current.contains(contactUuid)) {
      current.remove(contactUuid);
    } else {
      current.add(contactUuid);
    }
    await bloc.updateDraft(bloc.state.draft.copyWith(contacts: Value(current)));
  }

  /// Toggle an email invite on/off from the chip row (no pin refresh).
  Future<void> _toggleEmailInvite(String email) async {
    final bloc = context.read<PriorityBloc>();
    final thread = bloc.state.draft;
    final current = thread.inviteEmails;
    if (current.contains(email)) {
      final updated = current.where((e) => e != email).toList();
      await bloc.updateDraft(
        thread.copyWith(inviteEmails: Value(updated.isEmpty ? null : updated)),
      );
    } else {
      await bloc.updateDraft(
        thread.copyWith(inviteEmails: Value([...current, email])),
      );
    }
  }

  Future<void> _openSharedPicker(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    await context.run(
      PickDraftThreadShared(
        thread: priorityBloc.state.draft,
        onUpdate: (thread) async {
          if (!context.mounted) return;
          await priorityBloc.updateDraft(thread);
        },
      ),
    );
    if (!context.mounted) return;
    _refreshPinnedChips();
  }

  void _selectTwist(TwistInstance twist) {
    setState(() => _selectedTwist = twist);
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value('twist:${twist.twistId}')),
    );
    context.read<LocalPreferencesBloc>().recordMentionUsage(
      twist.id.toString(),
    );
  }

  String get _editorHint {
    if (_selectedTwist != null) return "Chat with ${_selectedTwist!.name}";
    return 'Start a thread';
  }

  List<ActorId>? get _twistMentions =>
      _selectedTwist != null ? [ActorId(_selectedTwist!.id)] : null;

  Future<void> _handleDraftChanged(Thread thread, {Note? note}) async {
    // Use the cached bloc: this callback can fire from NoteEditor.deactivate()
    // after ancestors are detached, so context.read would throw.
    final bloc = _priorityBloc;
    if (bloc == null) return;

    // Always use the latest state from the bloc as our base. This prevents
    // rapid typing in NoteEditor from regressing the contact list or twist icon
    // that might have been updated by other UI elements (like the share modal
    // or twist picker) while this callback was in flight.
    final currentThread = bloc.state.draft;
    final nextContacts = {...currentThread.contacts};
    bool contactsChanged = false;

    // 1. Extract and add non-twist mentions from the note content
    if (note?.mentions != null) {
      for (final mention in note!.mentions!) {
        if (mention.isTwist) continue;

        if (nextContacts.add(mention.toUuid())) {
          contactsChanged = true;
          // Pre-fetch missing actors so _refreshPinnedChips can show them immediately
          if (Actor.fromCache(mention) == null) {
            try {
              await Actor.getOne(mention);
            } catch (_) {}
          }
        }
      }
    }

    // 2. Also incorporate contacts from the 'thread' argument to ensure we don't
    // miss any legitimate updates from the NoteEditor (though rare for contacts).
    for (final id in thread.contacts) {
      if (nextContacts.add(id)) {
        contactsChanged = true;
      }
    }

    final updatedThread = currentThread.copyWith(
      contacts: contactsChanged
          ? Value(nextContacts.toList())
          : const Value.absent(),
      // Preserve other thread-level changes (like title/preview) from NoteEditor
      title: thread.title == currentThread.title
          ? const Value.absent()
          : Value(thread.title),
      preview: thread.preview == currentThread.preview
          ? const Value.absent()
          : Value(thread.preview),
    );

    // Update the bloc and persist changes.
    await bloc.updateDraft(updatedThread, note: note);

    if (contactsChanged && mounted) {
      _refreshPinnedChips();
    }
  }

  void _onChatSubmitted() {
    if (_selectedTwist != null) {
      context.read<LocalPreferencesBloc>().recordMentionUsage(
        _selectedTwist!.id.toString(),
      );
    }
    // Clear global search so the new thread is visible in the list
    _provider?.tryCloseSearch();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      // Only the multiPanel flag affects this page's layout. Skipping panel
      // visibility / width changes avoids redundant rebuilds of the editor
      // tree as the LayoutBloc emits during load.
      buildWhen: (prev, curr) => prev.multiPanel != curr.multiPanel,
      builder: (context, layoutState) {
        return BlocListener<PriorityBloc, PriorityState>(
          // Re-apply the default auto-file flag when the draft id changes
          // (chain drafts load async after mount or after submit) or when the
          // context changes (a PrioritiesPage click can mount NewThreadPage
          // with a stale PriorityBloc context before setPriority emits the
          // new root context — without listening for context we'd never
          // re-mark the draft as Auto on the way back to root).
          listenWhen: (prev, curr) =>
              prev.draft.id != curr.draft.id ||
              prev.context.id != curr.context.id,
          listener: (context, _) {
            if (!_hasAppliedQueryParams) return;
            _applyDefaultAutoFile();
          },
          child: BlocBuilder<PriorityBloc, PriorityState>(
            // During initial load PriorityBloc emits 6-10 times (agenda,
            // activity feed, tags, icon counts, twists, actors). Only the
            // fields below actually affect this page's chrome — rebuilding
            // for the rest forces a fresh NoteEditor widget each emit and
            // is the primary cause of the on-open editor flicker.
            //
            // `twists` and `actors` are deliberately excluded: in production
            // with many contacts the Drift `Actor.watch` stream emits many
            // times during initial sync, and rebuilding the chip row +
            // scaffold on each emit makes the page visibly flicker until
            // the stream settles. NoteEditor subscribes to those fields
            // internally via its own BlocBuilder so the inner Editor still
            // sees fresh @-mention candidates.
            buildWhen: (prev, curr) =>
                prev.draft != curr.draft ||
                prev.draftNote != curr.draftNote ||
                prev.context != curr.context,
            builder: (context, state) {
              final isViewerMode = state.draft.priority.isViewer;

              if (state.draft.priority.isTwistDev) {
                return Scaffold(
                  translucent: true,
                  scrollable: false,
                  childPad: false,
                  body: Center(
                    child: Text(
                      'Select a thread',
                      style: context.theme.typography.sm.copyWith(
                        color: context.theme.plotColors.muted,
                      ),
                    ),
                  ),
                );
              }

              return PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, result) {
                  if (!didPop) {
                    if (ModalProvider.tryDismissTopModal(context)) return;
                    final provider = ActivityPanelControllerProvider.maybeOf(
                      context,
                    );
                    if (provider != null && provider.tryCloseSearch()) return;
                    if (!context.isMultiPanel) {
                      context.run(ChangeCurrentThread(null));
                    }
                  }
                },
                child: CallbackShortcuts(
                  bindings: _buildThreadShortcuts(context, state),
                  child: Scaffold(
                    translucent: true,
                    scrollable: false,
                    childPad: false,
                    body: LayoutBuilder(
                      builder: (context, constraints) {
                        // Single panel mode: editor at bottom, edge-to-edge
                        if (!layoutState.multiPanel) {
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (!isViewerMode) ...[
                                Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.contentPaddingH,
                                  ),
                                  child: _buildThreadTypeSelector(
                                    context,
                                    state,
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],

                              Flexible(
                                child: NoteEditor(
                                  key: _threadEditorKey,
                                  draft: state.draftNote,
                                  thread: state.draft,
                                  onDraftChanged: _handleDraftChanged,
                                  flushToBottom: true,
                                  showScheduleActions: false,
                                  hint: state.draft.priority.isPlotApp
                                      ? 'Ask for help or share feedback'
                                      : _editorHint,
                                  additionalMentions: _twistMentions,
                                  onSubmitted: _onChatSubmitted,
                                  viewerMode: isViewerMode,
                                  selectedTwist: _selectedTwist,
                                  onTwistSelected: _selectTwist,
                                  onNavigateToThread: (thread) {
                                    context.run(ChangeCurrentThread(thread));
                                  },
                                ),
                              ),
                            ],
                          );
                        }

                        // Multi-panel mode: centered layout
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              Flexible(
                                child: SizedBox(
                                  height: constraints.maxHeight * 0.25,
                                ),
                              ),

                              if (!isViewerMode) ...[
                                _buildThreadTypeSelector(context, state),

                                SizedBox(height: 16),
                              ],

                              Flexible(
                                flex: 2,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: constraints.maxHeight * 0.5,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: NoteEditor(
                                          key: _threadEditorKey,
                                          draft: state.draftNote,
                                          thread: state.draft,
                                          onDraftChanged: _handleDraftChanged,
                                          flushToBottom: false,
                                          showScheduleActions: false,
                                          hint: state.draft.priority.isPlotApp
                                              ? 'Ask for help or share feedback'
                                              : _editorHint,
                                          additionalMentions: _twistMentions,
                                          onSubmitted: _onChatSubmitted,
                                          viewerMode: isViewerMode,
                                          selectedTwist: _selectedTwist,
                                          onTwistSelected: _selectTwist,
                                          onNavigateToThread: (thread) {
                                            context.run(
                                              ChangeCurrentThread(thread),
                                            );
                                          },
                                          autofocus: !isMobilePlatform(),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// Builds keyboard shortcut bindings for thread-level actions on the
  /// NewThreadPage: share (contacts). Note-level shortcuts are handled
  /// inside NoteEditor. Priority, title, and schedule are set via the
  /// priority chip / title input or after the thread is created.
  Map<ShortcutActivator, VoidCallback> _buildThreadShortcuts(
    BuildContext context,
    PriorityState state,
  ) {
    final isViewerMode = state.draft.priority.isViewer;
    if (isViewerMode) return const {};

    return {
      // ⌘⇧S — share (contacts)
      platformSingleActivator(LogicalKeyboardKey.keyS, shift: true): () {
        context.run(_ShareNewThread(onOpen: () => _openSharedPicker(context)));
      },
      // ⌘⇧P (⌘⌥⇧P on web) — change priority
      platformSingleActivator(
        LogicalKeyboardKey.keyP,
        shift: true,
        alt: kIsWeb,
      ): () {
        _selectPriority(context, state);
      },
      // ⌘⇧H — focus title input
      platformSingleActivator(LogicalKeyboardKey.keyH, shift: true): () {
        _titleInputKey.currentState?.focus();
      },
    };
  }
}

/// Opens the connection picker modal from the connection chip row's
/// trailing button. Icon switches to a "more" ellipsis when there are
/// additional create-targets beyond the pinned chips.
class _ConnectionPickerCommand extends Command {
  _ConnectionPickerCommand({required this.onOpen, bool hasMore = false})
    : super(
        title: 'Pick a connection',
        icon: hasMore ? PlotIcon.more : PlotIcon.shareAdd,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final Future<void> Function() onOpen;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onOpen();
    return const CommandDone();
  }
}

/// Opens the contact picker for the new-thread draft. Carries the ⌘⇧S
/// shortcut metadata so `Button.icon` displays the shortcut hint.
class _ShareNewThread extends Command {
  _ShareNewThread({required this.onOpen, bool hasMore = false})
    : super(
        title: 'Share with more',
        icon: hasMore ? PlotIcon.more : PlotIcon.shareAdd,
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
        shortcut: platformSingleActivator(LogicalKeyboardKey.keyS, shift: true),
      );

  final Future<void> Function() onOpen;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    await onOpen();
    return const CommandDone();
  }
}
