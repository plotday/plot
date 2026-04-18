import 'package:flutter/foundation.dart' show kIsWeb;
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

    // Auto-organize is ON by default only in the root ("Everything") priority
    // context and when the user has not explicitly picked or carried over a
    // priority. In a non-root context, the default is the most recent picker
    // priority (session-remembered) or the current context priority — never
    // auto — so the thread goes where the user is working.
    final bloc = context.read<PriorityBloc>();
    final hasExplicitPriority =
        widget.priorityId != null || bloc.newThreadDefaultPriority != null;
    if (bloc.state.context.root && !hasExplicitPriority) {
      ThreadsBase.autoFileIds.add(bloc.state.draft.id.toString());
    }

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

  /// Loads contacts for the "with" suggestion chips, sorted MRU → frequent →
  /// rest by [Actor.getSortedForSharing]. Scoped to the draft's currently
  /// selected priority so suggestions reflect who the user typically shares
  /// with in that priority, falling back to cross-priority MRU for actors
  /// with no history in this priority.
  Future<void> _loadRecentContacts() async {
    try {
      final priority = context.read<PriorityBloc>().state.draft.priority;
      final sorted = await Actor.getSortedForSharing(priority: priority);
      final recent = sorted.take(10).toList();
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

    // Resolve selected contacts to actors.
    // Note: If an actor isn't in cache, it's skipped here. _handleDraftChanged
    // fetches missing actors before calling this to ensure immediate display.
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
            'Start a thread in',
            style: context.theme.typography.sm.copyWith(
              color: context.theme.plotColors.veryMuted,
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildPriorityChipRow(context, state),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'with',
            style: context.theme.typography.sm.copyWith(
              color: context.theme.plotColors.veryMuted,
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildWithSelector(context, state),
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
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 8,
        children: [
          if (showLeadingSparkles) _buildAutoSparklesToggle(context),
          _buildPriorityChip(context, state, auto: auto),
        ],
      ),
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
          label,
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
        final priorities = await Priority.get(
          order: PriorityOrder.nested,
          search: search,
        );
        return [SelectGroup(title: null, items: priorities)];
      },
      itemBuilder: (priority, _) =>
          ListTile(body: PriorityLabel(priority: priority)),
      selectedValue: state.draft.priority,
      prompt: 'Select priority',
      onAdd: (ctx) =>
          createPriorityInline(ctx, parent: state.draft.priority),
    );
    if (!result.present) return;
    final picked = result.value;
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
      await bloc.updateDraft(bloc.state.draft.copyWith(priority: root));
    }
    if (mounted) _loadRecentContacts();
  }

  Future<void> _switchToPriority(Priority priority) async {
    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;
    setState(() {
      ThreadsBase.autoFileIds.remove(draft.id.toString());
    });
    if (priority.id != draft.priority.id) {
      await bloc.updateDraft(draft.copyWith(priority: priority));
    }
    bloc.setNewThreadDefaultPriority(priority);
    await _loadTwistsForPriority(priority);
    if (mounted) _loadRecentContacts();
  }

  /// Row showing the draft's thread type (with a chevron to change it) and
  /// either "Auto title" (sparkles → pencil on hover) or the title the user
  /// set (with an X to clear).
  Widget _buildAutoOrganizeLine(BuildContext context, PriorityState state) {
    final draft = state.draft;
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTypeChip(context, draft),
            _buildTitleChip(context, draft),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeChip(BuildContext context, Thread draft) {
    final subType =
        ThreadSubType.fromIcon(draft.icon) ?? ThreadSubType.defaultFor();
    final button = FButton(
      onPress: () => _openTypeModal(context, draft, subType),
      variant: FButtonVariant.ghost,
      style: ghostSizedStyleDelta(
        context,
        textStyle: context.theme.typography.sm,
      ),
      mainAxisSize: MainAxisSize.min,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          FaIcon(
            subType.icon,
            size: context.theme.iconSizes.base,
            color: context.theme.plotColors.veryMuted,
          ),
          Icon(
            PlotIcon.verticalExpand,
            size: context.theme.iconSizes.xs,
            color: context.theme.plotColors.veryMuted,
          ),
        ],
      ),
    );
    if (!hasPhysicalKeyboard()) return button;
    return FTooltip(
      tipBuilder: (context, controller) => _buildChipTooltip(
        context: context,
        label: subType.label,
        shortcut: platformSingleActivator(
          LogicalKeyboardKey.keyI,
          shift: true,
        ),
      ),
      child: button,
    );
  }

  Widget _buildTitleChip(BuildContext context, Thread draft) {
    final hasTitle = draft.title?.isNotEmpty ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HoverBuilder(
          builder: (context, hovered) {
            final IconData icon;
            final String label;
            final Color color;
            if (hasTitle) {
              icon = FontAwesomeIcons.pen;
              label = draft.title!;
              color = hovered
                  ? context.theme.colors.foreground
                  : context.theme.plotColors.muted;
            } else if (hovered) {
              icon = FontAwesomeIcons.pen;
              label = 'Set title';
              color = context.theme.plotColors.muted;
            } else {
              icon = PlotIcon.sparkles;
              label = 'Auto title';
              color = context.theme.plotColors.veryMuted;
            }
            final button = FButton(
              onPress: () => _openTitleModal(context, draft),
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
                  FaIcon(icon, size: context.theme.iconSizes.base, color: color),
                  Text(
                    label,
                    style: context.theme.typography.sm.copyWith(
                      color: color,
                      height: 1,
                    ),
                  ),
                ],
              ),
            );
            if (!hasPhysicalKeyboard()) return button;
            return FTooltip(
              tipBuilder: (context, controller) => _buildChipTooltip(
                context: context,
                label: hasTitle ? 'Edit title' : 'Set title',
                shortcut: platformSingleActivator(
                  LogicalKeyboardKey.keyH,
                  shift: true,
                ),
              ),
              child: button,
            );
          },
        ),
        if (hasTitle) _buildClearTitleButton(context, draft),
      ],
    );
  }

  Widget _buildClearTitleButton(BuildContext context, Thread draft) {
    final button = FButton.icon(
      onPress: () => _clearTitle(draft),
      variant: FButtonVariant.ghost,
      child: Icon(PlotIcon.close, size: context.theme.iconSizes.sm),
    );
    if (!hasPhysicalKeyboard()) return button;
    return FTooltip(
      tipBuilder: (context, controller) => const Text('Clear title'),
      child: button,
    );
  }

  Future<void> _clearTitle(Thread draft) async {
    final bloc = context.read<PriorityBloc>();
    await bloc.updateDraft(draft.copyWith(title: const Value(null)));
  }

  Future<void> _openTypeModal(
    BuildContext context,
    Thread draft,
    ThreadSubType current,
  ) async {
    final bloc = context.read<PriorityBloc>();
    final result = await SelectModal.open<ThreadSubType>(
      context,
      items: (_) async =>
          [SelectGroup(title: null, items: ThreadSubType.values)],
      itemBuilder: (subType, _) => ListTile(
        icon: subType.icon,
        body: Text(subType.label),
        selected: current == subType,
      ),
      selectedValue: current,
      prompt: 'Select type',
    );
    if (!result.present) return;
    await bloc.updateDraft(
      bloc.state.draft.copyWith(icon: Value(result.value.value)),
    );
  }

  Future<void> _openTitleModal(BuildContext context, Thread draft) async {
    final priorityBloc = context.read<PriorityBloc>();
    await context.run(
      ShowForm(
        title: 'Title',
        icon: FontAwesomeIcons.pen,
        form: (ctx) async {
          return FormData(
            title: 'Title',
            groups: [
              StaticFormGroup(
                items: [
                  FormTextInput(
                    key: 'title',
                    label: 'Title',
                    initialValue: draft.title,
                  ),
                  FormButton(
                    key: 'save',
                    buildCommand: (values) => _SaveDraftTitle(
                      (values['title'] as String?) ?? '',
                      priorityBloc: priorityBloc,
                    ),
                  ),
                ],
              ),
            ],
          );
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
    final lockedConfig = state.context.priorityConfig;
    final lockedGroupId = lockedConfig.group;

    // When a group is locked by priority config, hide the recent-contact
    // suggestion chips and replace them with a single selected, non-toggleable
    // group chip. The `+` button still opens the share picker.
    if (lockedGroupId != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildLockedGroupChip(
                context,
                lockedGroupId,
                label: lockedConfig.groupLabel,
              ),
              _buildAddContactChip(context, state, hasMore: false),
            ],
          ),
        ),
      );
    }

    // Render from pinned lists so chips stay stable when toggled via tap.
    // _pinnedActors and _pinnedEmails are only updated by _refreshPinnedChips
    // (called after modal changes and initial load).
    final displayedSelectedContacts = _pinnedActors
        .where((a) => selectedIds.contains(a.id.toUuid()))
        .length;
    final hasMore =
        selectedIds.length > displayedSelectedContacts ||
        pendingEmails.length > _pinnedEmails.length;

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

  /// Chip shown in place of the "with" suggestion chips when the draft's
  /// priority pins an auto-attached group (via `priority.config.group`).
  /// Renders as always-selected; tapping does nothing so the group cannot
  /// be removed from the thread.
  ///
  /// Prefers the config-provided [label] so the chip shows a stable name
  /// (e.g. "Plot Team") even when the resolved group's own name differs by
  /// environment (e.g. "Plot Publisher" fallback in dev). Falls back to the
  /// group's own name when no label is configured.
  Widget _buildLockedGroupChip(
    BuildContext context,
    Uuid groupId, {
    String? label,
  }) {
    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 10,
      vertical: isMobilePlatform() ? 10 : 5,
    );

    Widget buildChipWithText(String text) => FButton(
      onPress: () {},
      variant: FButtonVariant.primary,
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
      child: Text(text),
    );

    if (label != null && label.isNotEmpty) return buildChipWithText(label);

    return StreamBuilder<GroupRow?>(
      stream: Group.watchOne(groupId),
      builder: (context, snapshot) =>
          buildChipWithText(snapshot.data?.name ?? ''),
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

  Future<void> _handleDraftChanged(Thread thread, {Note? note}) async {
    if (!mounted) return;
    final bloc = context.read<PriorityBloc>();

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
      contacts: contactsChanged ? Value(nextContacts.toList()) : const Value.absent(),
      // Preserve other thread-level changes (like title/preview) from NoteEditor
      title: thread.title == currentThread.title ? const Value.absent() : Value(thread.title),
      preview: thread.preview == currentThread.preview ? const Value.absent() : Value(thread.preview),
    );

    // Update the bloc and persist changes.
    await bloc.updateDraft(updatedThread, note: note);

    if (contactsChanged) {
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
                              onDraftChanged: _handleDraftChanged,
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
                                        onDraftChanged: _handleDraftChanged,
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
  /// inside NoteEditor. Priority, title, type, and schedule are set via
  /// the priority chip / type chip / title chip or after the thread is
  /// created.
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
      // ⌘⇧H — change title (heading)
      platformSingleActivator(LogicalKeyboardKey.keyH, shift: true): () {
        _openTitleModal(context, state.draft);
      },
      // ⌘⇧I — change icon / type
      platformSingleActivator(LogicalKeyboardKey.keyI, shift: true): () {
        final draft = state.draft;
        final subType =
            ThreadSubType.fromIcon(draft.icon) ?? ThreadSubType.defaultFor();
        _openTypeModal(context, draft, subType);
      },
    };
  }
}

/// Saves (or clears) the draft title from the title modal.
class _SaveDraftTitle extends Command {
  _SaveDraftTitle(this.newTitle, {required this.priorityBloc})
    : super(
        title: 'Save',
        eventObject: EventObject.activity,
        eventAction: EventAction.updated,
      );

  final String newTitle;
  final PriorityBloc priorityBloc;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final trimmed = newTitle.trim();
    await priorityBloc.updateDraft(
      priorityBloc.state.draft.copyWith(
        title: Value(trimmed.isEmpty ? null : trimmed),
      ),
    );
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
