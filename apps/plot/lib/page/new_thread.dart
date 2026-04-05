import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

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
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/util/platform.dart';
import 'logging.dart';

enum NewThreadType { note, task, link, chat }

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
  static const _typeOrder = [
    NewThreadType.task, // Cmd/Ctrl+1
    NewThreadType.note, // Cmd/Ctrl+2
    NewThreadType.link, // Cmd/Ctrl+3
    NewThreadType.chat, // Cmd/Ctrl+4
  ];

  static final _typeShortcuts = [
    platformSingleActivator(LogicalKeyboardKey.digit1),
    platformSingleActivator(LogicalKeyboardKey.digit2),
    platformSingleActivator(LogicalKeyboardKey.digit3),
    platformSingleActivator(LogicalKeyboardKey.digit4),
  ];

  static final _twistShortcuts = [
    platformSingleActivator(LogicalKeyboardKey.digit1, shift: true),
    platformSingleActivator(LogicalKeyboardKey.digit2, shift: true),
    platformSingleActivator(LogicalKeyboardKey.digit3, shift: true),
  ];

  final GlobalKey<NoteEditorState> _threadEditorKey =
      GlobalKey<NoteEditorState>();

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;
  ThreadHeaderNotifier? _headerNotifier;
  bool _hasAppliedQueryParams = false;

  // Twists for the selected draft priority (may differ from context priority)
  List<PriorityTwist>? _draftTwists;

  late NewThreadType _selectedType;
  bool _hasMembers = false;
  ThreadSubType? _selectedSubType;

  // Selected twist for chat mode
  PriorityTwist? _selectedTwist;

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

    // Check if priority is shared (has members besides current user)
    _setHasMembers(context.read<PriorityBloc>().state.draft.priority.sharing);

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

  ThreadSubType _defaultSubType() {
    if (_selectedType == NewThreadType.task) return ThreadSubType.action;
    if (_hasMembers) {
      final priorityId = context
          .read<PriorityBloc>()
          .state
          .draft
          .priority
          .id
          .toString();
      return context
          .read<LocalPreferencesBloc>()
          .getSubTypeMru(priorityId)
          .first;
    }
    return ThreadSubType.forPriority(sharing: false).first;
  }

  void _setHasMembers(bool sharing) {
    if (sharing == _hasMembers) return;
    setState(() {
      _hasMembers = sharing;
      // Re-validate sub-type selection after sharing change
      if (_selectedSubType != null &&
          _selectedSubType!.sharedOnly &&
          !_hasMembers) {
        _selectedSubType = _defaultSubType();
        final bloc = context.read<PriorityBloc>();
        bloc.updateDraftLocal(
          bloc.state.draft.copyWith(icon: Value(_selectedSubType!.value)),
        );
      }
    });
  }

  void _resolveDefaultTwist() {
    final twists = _draftTwists ?? context.read<PriorityBloc>().state.twists;
    if (twists.isEmpty) {
      setState(() => _selectedTwist = null);
      return;
    }
    final sorted = _sortedTwists;
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

    // Default to private in priorities with viewers (safety measure)
    if (mounted) {
      final priority = context.read<PriorityBloc>().state.draft.priority;
      if (priority.isViewer) {
        // Viewers: always private
        final bloc = context.read<PriorityBloc>();
        if (!bloc.state.draft.private) {
          await bloc.updateDraft(bloc.state.draft.copyWith(private: true));
        }
      } else if (priority.sharing) {
        // Members: default to private if priority has viewers
        final viewers = await PriorityMember.getAcceptedViewersForPriority(
          priority.id,
        );
        if (viewers.isNotEmpty && mounted) {
          final bloc = context.read<PriorityBloc>();
          if (!bloc.state.draft.private) {
            await bloc.updateDraft(bloc.state.draft.copyWith(private: true));
          }
        }
      }
    }
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
        // queryPriority may come from getOne() which lacks sharing enrichment;
        // re-fetch enriched to get accurate sharing status
        final enriched = await Priority.get(
          id: queryPriority.id,
          archived: null,
        );
        if (mounted) {
          _setHasMembers(
            enriched.isNotEmpty
                ? enriched.first.sharing
                : queryPriority.sharing,
          );
        }
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
  /// If the priority matches the context priority, clears local state to use context twists.
  Future<void> _loadTwistsForPriority(Priority priority) async {
    final bloc = context.read<PriorityBloc>();
    if (priority.id == bloc.state.context.id) {
      // Priority matches context, use context twists (no need to load separately)
      setState(() {
        _draftTwists = null;
      });
    } else {
      // Load twists for the selected priority
      final twists = await PriorityTwist.get(priority: priority);
      setState(() {
        _draftTwists = twists;
      });
    }
    if (_selectedType == NewThreadType.chat) {
      _resolveDefaultTwist();
    }
  }

  Future<void> _selectPriority(
    BuildContext context,
    PriorityState state,
  ) async {
    final bloc = context.read<PriorityBloc>();
    final result = await SelectModal.open<Priority>(
      context,
      items: (search) async {
        final priorities = Priority.excludePlot(
          await Priority.get(order: PriorityOrder.nested, search: search),
        );
        return [SelectGroup(title: null, items: priorities)];
      },
      itemBuilder: (priority, _) =>
          ListTile(body: PriorityLabel(priority: priority)),
      selectedValue: state.draft.priority,
      prompt: 'Select Priority',
      onAdd: (ctx) =>
          createPriorityInline(ctx, parent: state.draft.priority),
    );

    if (result.present && result.value.id != state.draft.priority.id) {
      log.info(
        '[NewThreadPage._selectPriority] Updating draft priority from ${state.draft.priority.id} (${state.draft.priority.title}) to ${result.value.id} (${result.value.title})',
      );
      // Update just the draft's priority without changing the global priority context
      final updatedDraft = state.draft.copyWith(priority: result.value);
      await bloc.updateDraft(updatedDraft);
      bloc.setNewThreadDefaultPriority(result.value);

      // Load twists for the newly selected priority
      await _loadTwistsForPriority(result.value);

      // Check if the new priority has members (result is enriched from Priority.get)
      _setHasMembers(result.value.sharing);

      log.info(
        '[NewThreadPage._selectPriority] Draft priority update complete',
      );
    }
  }

  Widget _buildThreadTypeSelector(BuildContext context, PriorityState state) {
    final spacing = isMobilePlatform() ? 12.0 : 8.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            'Start a new thread in',
            style: context.theme.typography.sm.copyWith(
              color: context.theme.plotColors.veryMuted,
            ),
          ),
        ),
        SizedBox(height: 8),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 300),
            child: FButton(
              onPress: () => _selectPriority(context, state),
              variant: FButtonVariant.secondary,
              style: FButtonStyleDelta.delta(
                decoration: FVariantsDelta.delta([
                  FVariantOperation.all(
                    DecorationDelta.boxDelta(
                      borderRadius: const BorderRadius.all(Radius.circular(24)),
                      border: Border.all(color: context.theme.colors.border),
                    ),
                  ),
                ]),
                contentStyle: FButtonContentStyleDelta.delta(
                  padding: EdgeInsetsGeometryDelta.value(
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                ),
              ),
              mainAxisSize: MainAxisSize.min,
              suffix: Icon(
                PlotIcon.verticalExpand,
                size: 10,
                color: context.theme.colors.mutedForeground,
              ),
              child: Flexible(
                child: PriorityLabel(
                  priority: state.draft.priority,
                  muted: true,
                ),
              ),
            ),
          ),
        ),
        SizedBox(height: 24),

        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Button.icon(
                ToggleThreadToDo(
                  state.draft,
                  title: 'Start',
                  onUpdate: (thread) async {
                    if (!context.mounted) return;
                    await context.read<PriorityBloc>().updateDraft(thread);
                  },
                ),
                selected: state.draft.todo,
              ),
              _buildScheduleButton(context, state.draft, (thread) async {
                if (!context.mounted) return;
                await context.read<PriorityBloc>().updateDraft(thread);
              }),
              if (_hasMembers) ...[
                SizedBox(width: 4),
                Button.icon(
                  ToggleThreadPrivate(
                    state.draft,
                    onUpdate: (thread) async {
                      if (!context.mounted) return;
                      await context.read<PriorityBloc>().updateDraft(thread);
                    },
                  ),
                  selected: state.draft.private,
                ),
              ],
              _buildSubTypeButton(context),
            ],
          ),
        ),
        SizedBox(height: spacing),

        Builder(
          builder: (context) {
            // Hide labels when narrow (single panel)
            final showLabels = true;
            return Center(
              child: Wrap(
                spacing: spacing,
                runSpacing: spacing,
                alignment: WrapAlignment.center,
                children: [
                  _buildTypeChip(
                    context,
                    type: NewThreadType.task,
                    icon: PlotIcon.selfTask,
                    label: 'Task',
                    shortcutIndex: 0,
                    showLabel: showLabels,
                  ),
                  _buildTypeChip(
                    context,
                    type: NewThreadType.note,
                    icon: _hasMembers ? PlotIcon.message : PlotIcon.note,
                    label: _hasMembers ? 'Message' : 'Note',
                    shortcutIndex: 1,
                    showLabel: showLabels,
                  ),
                  _buildTypeChip(
                    context,
                    type: NewThreadType.link,
                    icon: PlotIcon.link,
                    label: 'Link',
                    shortcutIndex: 2,
                    showLabel: showLabels,
                  ),
                  _buildTypeChip(
                    context,
                    type: NewThreadType.chat,
                    icon: PlotIcon.twist,
                    label: 'Twist Chat',
                    shortcutIndex: 3,
                    showLabel: showLabels,
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildTwistLogo(
    BuildContext context,
    PriorityTwist twist, {
    double size = 14,
  }) {
    final isDark = context.colour.brightness == Brightness.dark;
    final url = isDark && twist.logoUrlDark != null
        ? twist.logoUrlDark
        : twist.logoUrl;
    if (url != null) {
      return LogoImage(url: url, size: size);
    }
    return Icon(PlotIcon.twist, size: size);
  }

  List<PriorityTwist> get _sortedTwists {
    final twists = _draftTwists ?? context.read<PriorityBloc>().state.twists;
    return context.read<LocalPreferencesBloc>().sortByMentionMru(
      twists,
      (t) => t.id.toString(),
    );
  }

  Widget _buildTwistSelector(BuildContext context) {
    final sorted = _sortedTwists;
    if (sorted.isEmpty) return const SizedBox.shrink();

    // Show up to 3 visible chips, plus ellipsis if more exist
    final visible = sorted.take(3).toList();
    final hasMore = sorted.length > 3;

    const chipRadius = BorderRadius.all(Radius.circular(24));
    final chipPadding = EdgeInsets.symmetric(
      horizontal: 12,
      vertical: isMobilePlatform() ? 12 : 6,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < visible.length; i++)
                _buildTwistChip(
                  context,
                  visible[i],
                  chipRadius,
                  chipPadding,
                  shortcutIndex: i,
                ),
              if (hasMore)
                FButton(
                  onPress: () => _openTwistPicker(context),
                  variant: FButtonVariant.secondary,
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
                  child: Text('...'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTwistChip(
    BuildContext context,
    PriorityTwist twist,
    BorderRadius chipRadius,
    EdgeInsets chipPadding, {
    int? shortcutIndex,
  }) {
    final selected = _selectedTwist?.id == twist.id;
    final chipStyleDelta = FButtonStyleDelta.delta(
      decoration: FVariantsDelta.delta([
        FVariantOperation.all(
          DecorationDelta.boxDelta(borderRadius: chipRadius),
        ),
      ]),
      contentStyle: FButtonContentStyleDelta.delta(
        padding: EdgeInsetsGeometryDelta.value(chipPadding),
      ),
    );
    Widget chip = FButton(
      onPress: () => _selectTwist(twist),
      variant: selected ? FButtonVariant.primary : FButtonVariant.secondary,
      style: chipStyleDelta,
      mainAxisSize: MainAxisSize.min,
      prefix: _buildTwistLogo(context, twist),
      child: Text(twist.name),
    );

    if (!kIsWeb &&
        hasPhysicalKeyboard() &&
        shortcutIndex != null &&
        shortcutIndex < _twistShortcuts.length) {
      chip = FTooltip(
        tipBuilder: (context, controller) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(twist.name),
            Text(
              formatShortcut(_twistShortcuts[shortcutIndex]),
              style: context.theme.typography.sm.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
          ],
        ),
        child: chip,
      );
    }

    return chip;
  }

  void _selectTwist(PriorityTwist twist) {
    setState(() => _selectedTwist = twist);
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value('twist:${twist.twistId}')),
    );
  }

  Future<void> _openTwistPicker(BuildContext context) async {
    final sorted = _sortedTwists;

    final result = await SelectModal.open<PriorityTwist>(
      context,
      items: (_) async => [SelectGroup(title: null, items: sorted)],
      itemBuilder: (twist, _) => ListTile(
        body: Row(
          spacing: 8,
          children: [_buildTwistLogo(context, twist), Text(twist.name)],
        ),
      ),
      selectedValue: _selectedTwist,
      prompt: 'Select Twist',
    );

    if (!context.mounted || !result.present) return;
    setState(() => _selectedTwist = result.value);
    // Set icon on draft
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value('twist:${result.value.twistId}')),
    );
    // Record MRU so the picked twist appears in the visible chips
    context.read<LocalPreferencesBloc>().recordMentionUsage(
      result.value.id.toString(),
    );
  }

  void _selectSubType(ThreadSubType subType) {
    setState(() => _selectedSubType = subType);
    final bloc = context.read<PriorityBloc>();
    bloc.updateDraftLocal(
      bloc.state.draft.copyWith(icon: Value(subType.value)),
    );
  }

  Widget _buildSubTypeButton(BuildContext context) {
    final subType = _selectedSubType;
    final disabled =
        _selectedType == NewThreadType.link ||
        _selectedType == NewThreadType.chat;

    if (subType == null || disabled) return const SizedBox.shrink();

    return FButton.icon(
      onPress: () => _showSubTypeOverflow(context),
      variant: FButtonVariant.ghost,
      style: FButtonStyleDelta.delta(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: BorderRadius.circular(24)),
          ),
        ]),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Icon(subType.icon, size: context.theme.iconSizes.base),
          Icon(PlotIcon.verticalExpand, size: context.theme.iconSizes.xs),
        ],
      ),
    );
  }

  Future<void> _showSubTypeOverflow(BuildContext context) async {
    final types = ThreadSubType.forPriority(sharing: _hasMembers);
    final priorityId = context
        .read<PriorityBloc>()
        .state
        .draft
        .priority
        .id
        .toString();
    final localPrefs = context.read<LocalPreferencesBloc>();

    final result = await SelectModal.open<ThreadSubType>(
      context,
      items: (_) async => [SelectGroup(title: null, items: types)],
      itemBuilder: (subType, _) => ListTile(
        icon: subType.icon,
        body: Text(subType.label),
        selected: _selectedSubType == subType,
      ),
      selectedValue: _selectedSubType,
      prompt: 'Select type',
    );

    if (!context.mounted || !result.present) return;
    await localPrefs.recordSubTypeMru(priorityId, result.value);
    _selectSubType(result.value);
  }

  String get _editorHint {
    switch (_selectedType) {
      case NewThreadType.task:
        return 'Describe the task';
      case NewThreadType.chat:
        return 'Message';
      default:
        return 'Write a note';
    }
  }

  List<ActorId>? get _chatMentions =>
      _selectedType == NewThreadType.chat && _selectedTwist != null
      ? [ActorId(_selectedTwist!.id)]
      : null;

  void _onChatSubmitted() {
    if (_selectedType == NewThreadType.chat && _selectedTwist != null) {
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
    // Initialize sub-type for note/task types
    if (_selectedType == NewThreadType.note ||
        _selectedType == NewThreadType.task) {
      _selectedSubType = _defaultSubType();
      bloc.updateDraftLocal(
        bloc.state.draft.copyWith(icon: Value(_selectedSubType!.value)),
      );
    }
  }

  void _selectType(NewThreadType type) {
    if (type == _selectedType) return;
    setState(() => _selectedType = type);
    context.read<LocalPreferencesBloc>().recordLastNewThreadType(type.name);

    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;

    if (type == NewThreadType.task && !draft.todo) {
      bloc.updateDraft(draft.toggleTag(Tag.todo));
    } else if (type != NewThreadType.task && draft.todo) {
      bloc.updateDraft(draft.toggleTag(Tag.todo));
    }

    if (type == NewThreadType.chat) {
      _selectedSubType = null;
      _resolveDefaultTwist();
    } else if (type == NewThreadType.link) {
      _selectedSubType = null;
      final currentDraft = bloc.state.draft;
      if (currentDraft.icon != null) {
        bloc.updateDraftLocal(currentDraft.copyWith(icon: const Value(null)));
      }
    } else {
      // Reset sub-type icon for note/task
      _selectedSubType = _defaultSubType();
      bloc.updateDraftLocal(
        bloc.state.draft.copyWith(icon: Value(_selectedSubType!.value)),
      );
    }
  }

  Widget _buildTypeChip(
    BuildContext context, {
    required NewThreadType type,
    required IconData icon,
    required String label,
    required int shortcutIndex,
    bool showLabel = true,
  }) {
    final selected = _selectedType == type;
    const chipRadius = BorderRadius.all(Radius.circular(24));

    Widget chip;
    if (showLabel && isMobilePlatform()) {
      // Mobile: stacked icon-above-label (narrower, fits 4 chips in a row)
      chip = FButton(
        onPress: () => _selectType(type),
        variant: selected ? FButtonVariant.primary : FButtonVariant.secondary,
        style: FButtonStyleDelta.delta(
          decoration: FVariantsDelta.delta([
            FVariantOperation.all(
              DecorationDelta.boxDelta(borderRadius: chipRadius),
            ),
          ]),
          contentStyle: FButtonContentStyleDelta.delta(
            padding: EdgeInsetsGeometryDelta.value(
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
          ),
        ),
        mainAxisSize: MainAxisSize.min,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: [
            Icon(icon, size: context.theme.iconSizes.base),
            Text(
              label,
              style: context.theme.typography.xs.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
          ],
        ),
      );
    } else {
      // Desktop: side-by-side icon + label
      final chipPadding = EdgeInsets.symmetric(
        horizontal: showLabel ? 12 : 10,
        vertical: isMobilePlatform() ? 12 : 6,
      );
      final typeChipStyleDelta = FButtonStyleDelta.delta(
        decoration: FVariantsDelta.delta([
          FVariantOperation.all(
            DecorationDelta.boxDelta(borderRadius: chipRadius),
          ),
        ]),
        contentStyle: FButtonContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(chipPadding),
        ),
      );
      chip = FButton(
        onPress: () => _selectType(type),
        variant: selected ? FButtonVariant.primary : FButtonVariant.secondary,
        style: typeChipStyleDelta,
        mainAxisSize: MainAxisSize.min,
        prefix: showLabel
            ? Icon(icon, size: context.theme.iconSizes.base)
            : null,
        child: showLabel
            ? Text(label)
            : Icon(icon, size: context.theme.iconSizes.lg),
      );
    }

    if (!kIsWeb && hasPhysicalKeyboard()) {
      chip = FTooltip(
        tipBuilder: (context, controller) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            Text(
              formatShortcut(_typeShortcuts[shortcutIndex]),
              style: context.theme.typography.sm.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
          ],
        ),
        child: chip,
      );
    }

    return chip;
  }

  Widget _buildScheduleButton(
    BuildContext context,
    Thread draft,
    Future<void> Function(Thread thread) onDraftChanged,
  ) {
    final isScheduled = draft.on?.start != null;
    final command = PickScheduleThread(draft, onUpdate: onDraftChanged);

    return Button.icon(command, selected: isScheduled);
  }

  Widget _buildLinkInput(
    BuildContext context,
    PriorityState state, {
    bool flushToBottom = false,
  }) {
    return LinkInput(
      priority: state.draft.priority,
      initialUrl: widget.sharedUrl,
      flushToBottom: flushToBottom,
      onNavigateToThread: (thread) {
        context.run(ChangeCurrentThread(thread));
      },
      onCreateLink: (url, title, favicon) {
        context.run(
          AddThreadWithLink(
            linkUrl: url,
            linkTitle: title,
            linkFavicon: favicon,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: kIsWeb
          ? {}
          : {
              for (var i = 0; i < _typeOrder.length; i++)
                _typeShortcuts[i]: () => _selectType(_typeOrder[i]),
              if (_selectedType == NewThreadType.chat)
                for (var i = 0; i < _twistShortcuts.length; i++)
                  _twistShortcuts[i]: () {
                    final sorted = _sortedTwists;
                    if (i < sorted.length) _selectTwist(sorted[i]);
                  },
            },
      child: BlocBuilder<LayoutBloc, LayoutState>(
        builder: (context, layoutState) {
          return BlocConsumer<PriorityBloc, PriorityState>(
            listener: (context, state) {
              // Sync sharing status when draft changes (e.g. _loadDraft
              // loads an enriched draft from the database)
              _setHasMembers(state.draft.priority.sharing);
            },
            builder: (context, state) {
              final priorityBloc = context.read<PriorityBloc>();

              final isViewerMode = state.draft.priority.isViewer;

              if (state.draft.priority.isTwistDev) {
                return Center(
                  child: Text(
                    'Select a thread',
                    style: context.theme.typography.sm.copyWith(
                      color: context.theme.plotColors.muted,
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
                              if (_selectedType == NewThreadType.chat)
                                Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: context.contentPaddingH,
                                  ),
                                  child: _buildTwistSelector(context),
                                ),
                              const SizedBox(height: 16),
                            ],

                            if (!isViewerMode &&
                                _selectedType == NewThreadType.link)
                              _buildLinkInput(
                                context,
                                state,
                                flushToBottom: true,
                              )
                            else
                              NoteEditor(
                                key: _threadEditorKey,
                                draft: state.draftNote,
                                thread: state.draft,
                                twists: _draftTwists ?? state.twists,
                                actors: state.actors,
                                onDraftChanged: (thread, {note}) async {
                                  if (!context.mounted) return;
                                  await priorityBloc.updateDraft(
                                    thread,
                                    note: note,
                                  );
                                },
                                flushToBottom: true,
                                showScheduleActions: false,
                                hint: state.draft.priority.isPlotApp
                                    ? 'Ask for help or share feedback'
                                    : _editorHint,
                                additionalMentions: _chatMentions,
                                onSubmitted: _onChatSubmitted,
                                assignNote:
                                    !isViewerMode &&
                                    _selectedType == NewThreadType.task,
                                viewerMode: isViewerMode,
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

                              if (_selectedType == NewThreadType.chat)
                                _buildTwistSelector(context),

                              SizedBox(height: 16),
                            ],

                            Flexible(
                              flex: 2,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: constraints.maxHeight * 0.5,
                                ),
                                child: !isViewerMode &&
                                        _selectedType == NewThreadType.link
                                    ? _buildLinkInput(context, state)
                                    : NoteEditor(
                                        key: _threadEditorKey,
                                        draft: state.draftNote,
                                        thread: state.draft,
                                        twists: _draftTwists ?? state.twists,
                                        actors: state.actors,
                                        onDraftChanged: (thread, {note}) async {
                                          if (!context.mounted) return;
                                          await context
                                              .read<PriorityBloc>()
                                              .updateDraft(thread, note: note);
                                        },
                                        flushToBottom: false,
                                        showScheduleActions: false,
                                        hint: state.draft.priority.isPlotApp
                                            ? 'Ask for help or share feedback'
                                            : _editorHint,
                                        additionalMentions: _chatMentions,
                                        onSubmitted: _onChatSubmitted,
                                        assignNote:
                                            !isViewerMode &&
                                            _selectedType == NewThreadType.task,
                                        viewerMode: isViewerMode,
                                      ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
