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
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;

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

  final GlobalKey<NoteEditorState> _threadEditorKey =
      GlobalKey<NoteEditorState>();

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;
  ThreadHeaderNotifier? _headerNotifier;
  bool _hasAppliedQueryParams = false;

  // Twists for the selected draft priority (may differ from context priority)
  List<PriorityTwist>? _draftTwists;

  NewThreadType _selectedType = NewThreadType.task;
  bool _hasMembers = false;

  // Selected twist for chat mode
  PriorityTwist? _selectedTwist;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Save the provider reference
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    // Register with ThreadHeaderNotifier so unified header knows NewThreadPage is visible
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
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
      _applyQueryParametersToDraft();
      // Default type is task, so ensure draft starts with todo on
      _applyDefaultType();
    }

    // Check members for initial priority
    _checkMembers(context.read<PriorityBloc>().state.draft.priority.id);
  }

  Future<void> _checkMembers(Uuid priorityId) async {
    final members = await PriorityMember.getForPriority(priorityId);
    if (mounted) {
      setState(() {
        _hasMembers = members.isNotEmpty;
      });
    }
  }

  void _resolveDefaultTwist() {
    final twists = _draftTwists ?? context.read<PriorityBloc>().state.twists;
    if (twists.isEmpty) {
      setState(() => _selectedTwist = null);
      return;
    }
    final sorted = _sortedTwists;
    setState(() => _selectedTwist = sorted.first);
  }

  Future<void> _applyQueryParametersToDraft() async {
    final bloc = context.read<PriorityBloc>();
    final currentDraft = bloc.state.draft;

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
      if (remembered.id != currentDraft.priority.id) {
        queryPriority = remembered;
      }
    }

    // Apply to draft if any query parameters were provided
    if (queryStartTime != null || queryPriority != null) {
      Thread updatedDraft;
      if (queryStartTime != null && queryEndTime != null) {
        // StartTime takes precedence - create a scheduled activity
        updatedDraft = currentDraft.copyWith(
          at: Value(DateTimeRange(queryStartTime, queryEndTime)),
          priority: queryPriority ?? currentDraft.priority,
          draft: true,
        );
        await bloc.updateDraft(updatedDraft);
      } else if (queryPriority != null) {
        updatedDraft = currentDraft.copyWith(
          priority: queryPriority,
          draft: true,
        );
        await bloc.updateDraft(updatedDraft);
      }

      // Load twists for the selected priority if different from context
      if (queryPriority != null) {
        await _loadTwistsForPriority(queryPriority);
        await _checkMembers(queryPriority.id);
      }
    }
  }

  @override
  void dispose() {
    // Unregister from the focus coordination provider using saved reference
    _provider?.unregisterActivityPanel();
    // Unregister from thread header notifier
    _headerNotifier?.unregister();
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
      itemBuilder: (priority) =>
          ListTile(body: PriorityLabel(priority: priority)),
      selectedValue: state.draft.priority,
      prompt: 'Select Priority',
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

      // Check if the new priority has members
      await _checkMembers(result.value.id);

      log.info(
        '[NewThreadPage._selectPriority] Draft priority update complete',
      );
    }
  }

  Widget _buildThreadTypeSelector(BuildContext context, PriorityState state) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Text(
            'Start a new thread in',
            style: context.theme.typography.sm.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
        ),
        SizedBox(height: 8),
        Center(
          child: FButton(
            onPress: () => _selectPriority(context, state),
            style: FButtonStyle.secondary((s) {
              final borderColor = context.theme.colors.border;
              return s.copyWith(
                decoration: _remapDecoration(
                  s.decoration,
                  const BorderRadius.all(Radius.circular(24)),
                  borderColor: borderColor,
                ),
                contentStyle: (c) => c.copyWith(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                ),
              );
            }),
            mainAxisSize: MainAxisSize.min,
            suffix: Icon(
              PlotIcon.verticalExpand,
              size: 10,
              color: context.theme.colors.mutedForeground,
            ),
            child: PriorityLabel(priority: state.draft.priority, muted: true),
          ),
        ),
        SizedBox(height: 24),

        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: .min,
              children: [
                Button.icon(
                  ToggleThreadToDo(
                    state.draft,
                    onUpdate: (thread) async {
                      await context.read<PriorityBloc>().updateDraft(thread);
                    },
                  ),
                  selected: state.draft.todo,
                ),
                _buildScheduleButton(context, state.draft, (thread) async {
                  await context.read<PriorityBloc>().updateDraft(thread);
                }),
              ],
            ),
            _buildTypeChip(
              context,
              type: NewThreadType.task,
              icon: PlotIcon.inbox,
              label: 'Task',
              shortcutIndex: 0,
            ),
            _buildTypeChip(
              context,
              type: NewThreadType.note,
              icon: PlotIcon.note,
              label: _hasMembers ? 'Message' : 'Note',
              shortcutIndex: 1,
            ),
            _buildTypeChip(
              context,
              type: NewThreadType.link,
              icon: PlotIcon.link,
              label: 'Link',
              shortcutIndex: 2,
            ),
            _buildTypeChip(
              context,
              type: NewThreadType.chat,
              icon: PlotIcon.twist,
              label: 'Twist Chat',
              shortcutIndex: 3,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTwistLogo(
    BuildContext context,
    PriorityTwist twist, {
    double size = 14,
  }) {
    final isDark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
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
    const chipPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 6);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final twist in visible)
                _buildTwistChip(context, twist, chipRadius, chipPadding),
              if (hasMore)
                FButton(
                  onPress: () => _openTwistPicker(context),
                  style: FButtonStyle.secondary(
                    (s) => s.copyWith(
                      decoration: _remapDecoration(s.decoration, chipRadius),
                      contentStyle: (c) => c.copyWith(padding: chipPadding),
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
    EdgeInsets chipPadding,
  ) {
    final selected = _selectedTwist?.id == twist.id;
    return FButton(
      onPress: () => _selectTwist(twist),
      style: selected
          ? FButtonStyle.primary(
              (s) => s.copyWith(
                decoration: _remapDecoration(s.decoration, chipRadius),
                contentStyle: (c) => c.copyWith(padding: chipPadding),
              ),
            )
          : FButtonStyle.secondary(
              (s) => s.copyWith(
                decoration: _remapDecoration(s.decoration, chipRadius),
                contentStyle: (c) => c.copyWith(padding: chipPadding),
              ),
            ),
      mainAxisSize: MainAxisSize.min,
      prefix: _buildTwistLogo(context, twist),
      child: Text(twist.name),
    );
  }

  void _selectTwist(PriorityTwist twist) {
    setState(() => _selectedTwist = twist);
  }

  Future<void> _openTwistPicker(BuildContext context) async {
    final sorted = _sortedTwists;

    final result = await SelectModal.open<PriorityTwist>(
      context,
      items: (_) async => [SelectGroup(title: null, items: sorted)],
      itemBuilder: (twist) => ListTile(
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
    // Record MRU so the picked twist appears in the visible chips
    context.read<LocalPreferencesBloc>().recordMentionUsage(
      result.value.id.toString(),
    );
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
  }

  void _applyDefaultType() {
    if (_selectedType == NewThreadType.task) {
      final bloc = context.read<PriorityBloc>();
      final draft = bloc.state.draft;
      if (!draft.todo) {
        bloc.updateDraft(draft.toggleTag(Tag.todo));
      }
    }
  }

  void _selectType(NewThreadType type) {
    if (type == _selectedType) return;
    setState(() => _selectedType = type);

    final bloc = context.read<PriorityBloc>();
    final draft = bloc.state.draft;

    if (type == NewThreadType.task && !draft.todo) {
      bloc.updateDraft(draft.toggleTag(Tag.todo));
    } else if (type != NewThreadType.task && draft.todo) {
      bloc.updateDraft(draft.toggleTag(Tag.todo));
    }

    if (type == NewThreadType.chat) {
      _resolveDefaultTwist();
    }
  }

  Widget _buildTypeChip(
    BuildContext context, {
    required NewThreadType type,
    required IconData icon,
    required String label,
    required int shortcutIndex,
  }) {
    final selected = _selectedType == type;
    const chipRadius = BorderRadius.all(Radius.circular(24));
    const chipPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 6);
    Widget chip = FButton(
      onPress: () => _selectType(type),
      style: selected
          ? FButtonStyle.primary(
              (s) => s.copyWith(
                decoration: _remapDecoration(s.decoration, chipRadius),
                contentStyle: (c) => c.copyWith(padding: chipPadding),
              ),
            )
          : FButtonStyle.secondary(
              (s) => s.copyWith(
                decoration: _remapDecoration(s.decoration, chipRadius),
                contentStyle: (c) => c.copyWith(padding: chipPadding),
              ),
            ),
      mainAxisSize: MainAxisSize.min,
      prefix: Icon(icon, size: 14),
      child: Text(label),
    );

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

  static FWidgetStateMap<BoxDecoration> _remapDecoration(
    FWidgetStateMap<BoxDecoration> source,
    BorderRadius radius, {
    Color? borderColor,
  }) {
    BoxDecoration applyBorder(BoxDecoration d) {
      var result = d.copyWith(borderRadius: radius);
      if (borderColor != null && d.border is Border) {
        final b = d.border! as Border;
        result = result.copyWith(
          border: Border(
            top: b.top.copyWith(color: borderColor),
            right: b.right.copyWith(color: borderColor),
            bottom: b.bottom.copyWith(color: borderColor),
            left: b.left.copyWith(color: borderColor),
          ),
        );
      }
      return result;
    }

    return FWidgetStateMap({
      WidgetState.disabled: applyBorder(source.resolve({WidgetState.disabled})),
      WidgetState.hovered | WidgetState.pressed: applyBorder(
        source.resolve({WidgetState.hovered}),
      ),
      WidgetState.any: applyBorder(source.resolve({})),
    });
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
      flushToBottom: flushToBottom,
      onNavigateToThread: (thread) {
        context.run(ChangeCurrentThread(thread));
      },
      onCreateLink: (url, title, favicon) {
        context.run(AddThreadWithLink(linkUrl: url, linkTitle: title, linkFavicon: favicon));
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
            },
      child: BlocBuilder<LayoutBloc, LayoutState>(
        builder: (context, layoutState) {
          return BlocBuilder<PriorityBloc, PriorityState>(
            builder: (context, state) {
              return PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, result) {
                  if (!didPop) {
                    if (ModalProvider.tryDismissTopModal(context)) return;
                    final provider =
                        ActivityPanelControllerProvider.maybeOf(context);
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

                            if (_selectedType == NewThreadType.link)
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
                                  await context
                                      .read<PriorityBloc>()
                                      .updateDraft(thread, note: note);
                                },
                                flushToBottom: true,
                                showScheduleActions: false,
                                hint: _editorHint,
                                additionalMentions: _chatMentions,
                                onSubmitted: _onChatSubmitted,
                                assignNote: _selectedType == NewThreadType.task,
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

                            _buildThreadTypeSelector(context, state),

                            if (_selectedType == NewThreadType.chat)
                              _buildTwistSelector(context),

                            SizedBox(height: 16),

                            Flexible(
                              flex: 2,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: constraints.maxHeight * 0.5,
                                ),
                                child: _selectedType == NewThreadType.link
                                    ? _buildLinkInput(context, state)
                                    : NoteEditor(
                                        key: _threadEditorKey,
                                        draft: state.draftNote,
                                        thread: state.draft,
                                        twists: _draftTwists ?? state.twists,
                                        actors: state.actors,
                                        onDraftChanged: (thread, {note}) async {
                                          await context
                                              .read<PriorityBloc>()
                                              .updateDraft(thread, note: note);
                                        },
                                        flushToBottom: false,
                                        showScheduleActions: false,
                                        hint: _editorHint,
                                        additionalMentions: _chatMentions,
                                        onSubmitted: _onChatSubmitted,
                                        assignNote: _selectedType == NewThreadType.task,
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
