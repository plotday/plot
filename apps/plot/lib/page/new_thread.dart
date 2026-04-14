import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/state/priority.dart';

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/store/store.dart';
import 'package:plot/style/button.dart' show ghostSizedStyleDelta;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/analytics/tracker.dart';
import 'logging.dart';

enum NewThreadType { note, task, link, chat }

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

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;
  ThreadHeaderNotifier? _headerNotifier;
  bool _hasAppliedQueryParams = false;

  // Twists for the selected draft priority (may differ from context priority)
  List<TwistInstance>? _draftTwists;

  late NewThreadType _selectedType;

  /// Contacts the user has recently shared threads with, for suggestions.
  List<Actor> _recentContacts = const [];

  /// Pinned actors shown in the "with" chip row. Only updated when the modal
  /// changes contacts — tapping a chip toggles selected state without removing
  /// the chip, so the row stays stable.
  List<Actor> _pinnedActors = const [];

  /// Pinned email invites shown in the chip row. Same stability rule.
  List<String> _pinnedEmails = const [];

  // Selected twist for chat mode
  TwistInstance? _selectedTwist;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Save the provider reference
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    // Register with ThreadHeaderNotifier so unified header knows NewThreadPage is visible
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
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
      );
      _provider?.registerActivityPanel(
        editorFocusCallback: () => _threadEditorKey.currentState?.focus(),
      );
    });

    // Apply query parameters and default type to draft
    if (!_hasAppliedQueryParams) {
      _hasAppliedQueryParams = true;
      if (widget.sharedUrl != null) {
        _selectedType = NewThreadType.link;
      } else {
        _selectedType = _loadDefaultType();
      }
      _initializeDraft();
    }
  }

  void _resolveDefaultTwist() {
    final twists = _draftTwists ?? context.read<PriorityBloc>().state.twists;
    if (twists.isEmpty) {
      setState(() => _selectedTwist = null);
      return;
    }
    final sorted = context.read<LocalPreferencesBloc>().sortByMentionMru(
      twists,
      (t) => t.id.toString(),
    );
    setState(() => _selectedTwist = sorted.first);
    // Set icon on draft
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(
        icon: Value('twist:${_selectedTwist!.twistId}'),
      ),
    );
  }

  /// Sequences query parameter application and default type initialization.
  /// Must be async because _applyQueryParametersToDraft awaits DB lookups;
  /// _applyDefaultType must run AFTER those complete so its draft changes
  /// (icon, todo) aren't overwritten by the stale copyWith in the query method.
  Future<void> _initializeDraft() async {
    await _applyQueryParametersToDraft();
    if (!mounted) return;
    _applyDefaultType();

    // Default to auto-organize ON: thread files in the current context
    // priority immediately, and the server re-files it on sync (via
    // `auto_file` → `classify_thread_for_user`). Saving EditThread from
    // the Auto organize line removes the id from this set, turning it OFF.
    final bloc = context.read<PriorityBloc>();
    ThreadsBase.autoFileIds.add(bloc.state.draft.id.toString());

    // Load recently shared contacts for suggestion chips
    _loadRecentContacts();
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

      // Load twists for the selected priority if different from context
      if (queryPriority != null) {
        await _loadTwistsForPriority(queryPriority);
      }
    }
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

  /// Loads twists for the given priority and updates local state.
  /// Twists are workspace-level now, so the same list applies regardless of
  /// which priority is selected. Kept as a no-op hook so callers don't need to
  /// branch, and so draft mode still triggers default-twist resolution.
  Future<void> _loadTwistsForPriority(Priority priority) async {
    setState(() {
      _draftTwists = null;
    });
    if (_selectedType == NewThreadType.chat) {
      _resolveDefaultTwist();
    }
  }

  /// Loads contacts the user has recently shared threads with, for suggestion
  /// chips in the "with" row.
  Future<void> _loadRecentContacts() async {
    try {
      final selfIds = Actor.getCurrentUserActorIds()
          .map((a) => a.toUuid())
          .toSet();
      final threads = await Thread.get(
        draft: false,
        archived: false,
        limit: 30,
      );
      final seen = <Uuid>{};
      final recent = <Actor>[];
      for (final thread in threads) {
        for (final contactId in thread.contacts) {
          if (!selfIds.contains(contactId) && seen.add(contactId)) {
            final actor = Actor.fromCache(ActorId.fromUuid(contactId));
            if (actor != null) recent.add(actor);
            if (recent.length >= 10) break;
          }
        }
        if (recent.length >= 10) break;
      }
      if (mounted) {
        setState(() => _recentContacts = recent);
        _refreshPinnedChips();
      }
    } catch (e, t) {
      log.warning('[NewThreadPage._loadRecentContacts] failed', e, t);
    }
  }

  /// Rebuilds the pinned chip list from current draft state + recent contacts.
  /// Call after modal changes or initial load — NOT after chip taps.
  void _refreshPinnedChips() {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    final selectedIds = draft.contacts.toSet();
    final pendingEmails = draft.inviteEmails;

    // Resolve selected contacts to actors
    final selected = selectedIds
        .map((id) => Actor.fromCache(ActorId.fromUuid(id)))
        .where((a) => a != null)
        .cast<Actor>()
        .toList();

    // Budget: 3 total chips
    final selectedChipCount = selected.length.clamp(0, 3);
    final emailSlots = (3 - selectedChipCount).clamp(0, 3);
    final emailChipCount = pendingEmails.length.clamp(0, emailSlots);
    final suggestionSlots = 3 - selectedChipCount - emailChipCount;

    final suggestions = _recentContacts
        .where((a) => !selectedIds.contains(a.id.toUuid()))
        .take(suggestionSlots)
        .toList();

    setState(() {
      _pinnedActors = [...selected.take(3), ...suggestions];
      _pinnedEmails = pendingEmails.take(emailSlots).toList();
    });
  }

  Widget _buildThreadTypeSelector(BuildContext context, PriorityState state) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            'Start a thread with',
            style: context.theme.typography.sm.copyWith(
              color: context.theme.plotColors.veryMuted,
            ),
          ),
        ),
        SizedBox(height: 8),
        _buildWithSelector(context, state),
      ],
    );
  }

  /// Single inline control that replaces the old action bar. In "Auto
  /// organize" state (draft id present in [ThreadsBase.autoFileIds]), clicking
  /// opens [EditThread] so the user can set priority/title/type; saving the
  /// modal flips off auto-organize and this row shows what the user picked.
  Widget _buildAutoOrganizeLine(BuildContext context, PriorityState state) {
    final draft = state.draft;
    final autoOrganize = ThreadsBase.autoFileIds.contains(draft.id.toString());
    final child = autoOrganize
        ? _buildAutoOrganizeButton(context)
        : _buildOrganizedRow(context, draft);
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 4),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
  }

  Widget _buildAutoOrganizeButton(BuildContext context) {
    final button = FButton(
      onPress: () => _openEditThreadFromAutoOrganize(context),
      variant: FButtonVariant.ghost,
      style: ghostSizedStyleDelta(
        context,
        textStyle: context.theme.typography.sm,
      ),
      mainAxisSize: MainAxisSize.min,
      prefix: const Icon(PlotIcon.sparkles),
      child: const Text('Auto organize'),
    );
    if (!hasPhysicalKeyboard()) return button;
    return FTooltip(
      tipBuilder: (context, controller) =>
          const Text('Set priority, title, and thread type'),
      child: button,
    );
  }

  Widget _buildOrganizedRow(BuildContext context, Thread draft) {
    final subType =
        ThreadSubType.fromIcon(draft.icon) ?? ThreadSubType.defaultFor();
    final hasTitle = draft.title?.isNotEmpty ?? false;
    final displayTitle = hasTitle ? draft.title! : 'Auto title';
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _HoverBuilder(
          builder: (context, hovered) {
            final titleColor = hovered
                ? context.theme.colors.foreground
                : (hasTitle
                      ? context.theme.plotColors.muted
                      : context.theme.plotColors.veryMuted);
            final mutedColor = hovered
                ? context.theme.plotColors.muted
                : context.theme.plotColors.veryMuted;
            final titleStyle = context.theme.typography.sm.copyWith(
              color: titleColor,
              height: 1,
            );
            final mutedStyle = context.theme.typography.sm.copyWith(
              color: mutedColor,
              height: 1,
            );
            return FButton(
              onPress: () => _openEditThreadFromAutoOrganize(context),
              variant: FButtonVariant.ghost,
              style: ghostSizedStyleDelta(
                context,
                textStyle: context.theme.typography.sm,
              ),
              mainAxisSize: MainAxisSize.min,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  FaIcon(
                    subType.icon,
                    size: context.theme.iconSizes.base,
                    color: titleColor,
                  ),
                  Text(displayTitle, style: titleStyle),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('(', style: mutedStyle),
                      PriorityLabel(
                        priority: draft.priority,
                        color: mutedColor,
                        fontSize: context.theme.typography.sm.fontSize,
                        height: 1,
                      ),
                      Text(')', style: mutedStyle),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
        _buildResetAutoOrganizeButton(context, draft),
      ],
    );
  }

  Widget _buildResetAutoOrganizeButton(BuildContext context, Thread draft) {
    final button = FButton.icon(
      onPress: () => _resetAutoOrganize(draft),
      variant: FButtonVariant.ghost,
      child: Icon(PlotIcon.close, size: context.theme.iconSizes.sm),
    );
    if (!hasPhysicalKeyboard()) return button;
    return FTooltip(
      tipBuilder: (context, controller) => const Text('Auto organize'),
      child: button,
    );
  }

  Future<void> _resetAutoOrganize(Thread draft) async {
    final bloc = context.read<PriorityBloc>();
    // Clear the user's pick so the organized row reverts to "Auto organize".
    await bloc.updateDraft(
      draft.copyWith(
        priority: bloc.state.context,
        title: const Value(null),
        icon: const Value(null),
      ),
    );
    if (!mounted) return;
    setState(() {
      ThreadsBase.autoFileIds.add(draft.id.toString());
    });
  }

  Future<void> _openEditThreadFromAutoOrganize(BuildContext context) async {
    final priorityBloc = context.read<PriorityBloc>();
    final draft = priorityBloc.state.draft;
    final draftId = draft.id.toString();
    await context.run(
      EditThread(
        draft,
        priorityBloc: priorityBloc,
        onSaved: () {
          if (!mounted) return;
          setState(() {
            ThreadsBase.autoFileIds.remove(draftId);
          });
        },
      ),
    );
  }

  /// Build the "With" chip row: the current user can tap recent contacts
  /// to add or remove them from the thread, or tap the `+` button to open
  /// a searchable picker modal. Selected contacts flow into
  /// `state.draft.contacts`. Up to 3 chips are shown (selected actors +
  /// pending email invites + recent suggestions), plus a more/add button.
  Widget _buildWithSelector(BuildContext context, PriorityState state) {
    final selectedIds = state.draft.contacts.toSet();
    final pendingEmails = state.draft.inviteEmails.toSet();

    // Render from pinned lists so chips stay stable when toggled via tap.
    // _pinnedActors and _pinnedEmails are only updated by _refreshPinnedChips
    // (called after modal changes and initial load).
    final hasMore =
        _pinnedActors.length + _pinnedEmails.length >= 3 ||
        _recentContacts
                .where((a) => !selectedIds.contains(a.id.toUuid()))
                .length >
            _pinnedActors
                .where((a) => !selectedIds.contains(a.id.toUuid()))
                .length;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
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
                _buildAddContactChip(context, state, hasMore: hasMore),
              ],
            ),
          ],
        ),
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
        child: Text(
          actor.name ?? actor.email ?? 'Unknown',
          style: (!selected && !hovered)
              ? TextStyle(color: context.theme.plotColors.veryMuted)
              : null,
        ),
      );
    }

    if (selected) return buildChip(false);
    return _HoverBuilder(builder: (context, hovered) => buildChip(hovered));
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
    return 'Add a note';
  }

  List<ActorId>? get _twistMentions =>
      _selectedTwist != null ? [ActorId(_selectedTwist!.id)] : null;

  void _onChatSubmitted() {
    if (_selectedTwist != null) {
      context.read<LocalPreferencesBloc>().recordMentionUsage(
        _selectedTwist!.id.toString(),
      );
    }
    // Clear global search so the new thread is visible in the list
    _provider?.tryCloseSearch();
  }

  NewThreadType _loadDefaultType() {
    final saved = context.read<LocalPreferencesBloc>().state.lastNewThreadType;
    if (saved != null) {
      for (final type in NewThreadType.values) {
        if (type.name == saved) return type;
      }
    }
    return NewThreadType.task;
  }

  void _applyDefaultType() {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    if (_selectedType == NewThreadType.task && !draft.todo) {
      bloc.updateDraftLocal(draft.toggleTag(Tag.todo));
    } else if (_selectedType != NewThreadType.task && draft.todo) {
      bloc.updateDraftLocal(draft.toggleTag(Tag.todo));
    }
    if (_selectedType == NewThreadType.chat) {
      _resolveDefaultTwist();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            final priorityBloc = context.read<PriorityBloc>();

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
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            Spacer(),

                            if (!isViewerMode) ...[
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: context.contentPaddingH,
                                ),
                                child: _buildThreadTypeSelector(context, state),
                              ),
                              const SizedBox(height: 16),
                            ],

                            if (!isViewerMode)
                              Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: context.contentPaddingH,
                                ),
                                child: _buildAutoOrganizeLine(context, state),
                              ),

                            NoteEditor(
                              key: _threadEditorKey,
                              draft: state.draftNote,
                              thread: state.draft,
                              twists: _draftTwists ?? state.twists,
                              actors: state.actors,
                              onDraftChanged: (thread, {note}) async {
                                if (!context.mounted) return;
                                final prevContacts = priorityBloc
                                    .state
                                    .draft
                                    .contacts
                                    .toSet();
                                await priorityBloc.updateDraft(
                                  thread,
                                  note: note,
                                );
                                final nextContacts = thread.contacts.toSet();
                                if (nextContacts.length !=
                                        prevContacts.length ||
                                    !nextContacts.containsAll(prevContacts)) {
                                  _refreshPinnedChips();
                                }
                              },
                              flushToBottom: true,
                              showScheduleActions: false,
                              hint: state.draft.priority.isPlotApp
                                  ? 'Ask for help or share feedback'
                                  : _editorHint,
                              additionalMentions: _twistMentions,
                              onSubmitted: _onChatSubmitted,
                              assignNote: !isViewerMode,
                              viewerMode: isViewerMode,
                              selectedTwist: _selectedTwist,
                              onTwistSelected: _selectTwist,
                              onNavigateToThread: (thread) {
                                context.run(ChangeCurrentThread(thread));
                              },
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
                                    if (!isViewerMode)
                                      _buildAutoOrganizeLine(context, state),
                                    Flexible(
                                      child: NoteEditor(
                                        key: _threadEditorKey,
                                        draft: state.draftNote,
                                        thread: state.draft,
                                        twists: _draftTwists ?? state.twists,
                                        actors: state.actors,
                                        onDraftChanged: (thread, {note}) async {
                                          if (!context.mounted) return;
                                          final bloc = context
                                              .read<PriorityBloc>();
                                          final prevContacts = bloc
                                              .state
                                              .draft
                                              .contacts
                                              .toSet();
                                          await bloc.updateDraft(
                                            thread,
                                            note: note,
                                          );
                                          final nextContacts = thread.contacts
                                              .toSet();
                                          if (nextContacts.length !=
                                                  prevContacts.length ||
                                              !nextContacts.containsAll(
                                                prevContacts,
                                              )) {
                                            _refreshPinnedChips();
                                          }
                                        },
                                        flushToBottom: false,
                                        showScheduleActions: false,
                                        hint: state.draft.priority.isPlotApp
                                            ? 'Ask for help or share feedback'
                                            : _editorHint,
                                        additionalMentions: _twistMentions,
                                        onSubmitted: _onChatSubmitted,
                                        assignNote: !isViewerMode,
                                        viewerMode: isViewerMode,
                                        selectedTwist: _selectedTwist,
                                        onTwistSelected: _selectTwist,
                                        onNavigateToThread: (thread) {
                                          context.run(
                                            ChangeCurrentThread(thread),
                                          );
                                        },
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
        );
      },
    );
  }

  /// Builds keyboard shortcut bindings for thread-level actions on the
  /// NewThreadPage: share (contacts). Note-level shortcuts are handled
  /// inside NoteEditor. Priority and schedule no longer have pre-save
  /// shortcuts — those are set via the Auto organize (EditThread) modal or
  /// after the thread is created.
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
    };
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
