import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/state/priority.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/layout.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;

@RoutePage(name: "ThreadRoute")
class ThreadPage implements AutoRouteWrapper {
  ThreadPage({@PathParam("threadId") required String threadIdString})
    : threadId = ThreadId.fromShortString(threadIdString);

  final ThreadId threadId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return ThreadBlocProvider(
      threadId: threadId,
      thread: null, // Let the bloc load the thread
      child: BlocConsumer<ThreadBloc, ThreadState>(
        listener: (context, state) {
          context.read<PriorityBloc>().setThread(state.thread);
        },
        listenWhen: (previous, current) =>
            previous.thread.id != current.thread.id,
        builder: (context, state) {
          return _ThreadPageContent();
        },
      ),
    );
  }
}

class _ThreadPageContent extends StatefulWidget {
  const _ThreadPageContent();

  @override
  State<_ThreadPageContent> createState() => _ThreadPageContentState();
}

class _ThreadPageContentState extends State<_ThreadPageContent> {
  final GlobalKey<NoteEditorState> _noteEditorKey =
      GlobalKey<NoteEditorState>();

  // Store reference to provider to avoid unsafe ancestor lookup in dispose()
  PriorityShortcutsProviderState? _provider;

  // Store reference to thread header notifier
  ThreadHeaderNotifier? _headerNotifier;

  // Timer for delayed read marking
  Timer? _markReadTimer;

  // Flag to ensure setActivity is only called once on initial load
  bool _hasSetInitialActivity = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Save reference during a safe lifecycle method
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
    // Schedule marking thread as read after 750ms
    _scheduleMarkAsRead();

    // Prefer middle panel on resize while ThreadPage is visible
    context.read<LayoutBloc>().preferMiddle = true;

    // Ensure PriorityBloc knows about this thread on first load
    if (!_hasSetInitialActivity) {
      _hasSetInitialActivity = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final thread = context.read<ThreadBloc>().state.thread;
          context.read<PriorityBloc>().setThread(thread);
        }
      });
    }

    // Register with ThreadHeaderNotifier for unified header search
    // Deferred to avoid notifyListeners() during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _registerWithHeaderNotifier();
    });
  }

  void _registerWithHeaderNotifier() {
    final state = context.read<ThreadBloc>().state;
    _headerNotifier?.register(
      onSearchChanged: (search) =>
          context.read<ThreadBloc>().updateSearch(search),
      onSearchClosed: () {
        context.read<ThreadBloc>().updateFilter([]);
        context.read<ThreadBloc>().setThreadFilter(null);
      },
      tags: state.tags,
      filter: state.filter,
    );

    // Apply current search from PriorityBloc so notes are filtered
    // when navigating between threads while search is active
    final currentSearch = context.read<PriorityBloc>().state.search;
    if (currentSearch.isNotEmpty) {
      context.read<ThreadBloc>().updateSearch(currentSearch);
    }
  }

  @override
  void dispose() {
    // Cancel the mark-as-read timer if still pending
    _markReadTimer?.cancel();
    // Unregister from the focus coordination provider
    // Use saved reference instead of looking up during dispose()
    _provider?.unregisterActivityPanel();
    // Unregister from thread header notifier
    _headerNotifier?.unregister();
    // Clear middle panel preference when leaving ThreadPage
    LayoutBloc.instance?.preferMiddle = false;
    super.dispose();
  }

  /// Schedules marking the thread as read after 750ms.
  /// Cancels any previously scheduled mark-as-read operation.
  void _scheduleMarkAsRead() {
    // Cancel any existing timer
    _markReadTimer?.cancel();

    // Start new timer for 750ms delay
    _markReadTimer = Timer(const Duration(milliseconds: 750), () {
      final thread = context.read<ThreadBloc>().state.thread;
      if (thread.unread) {
        thread.copyWith(unread: false).save();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ThreadBloc, ThreadState>(
      listener: (context, state) {
        // Update header notifier when tags/filter change
        _headerNotifier?.updateTags(state.tags, state.filter);
      },
      listenWhen: (previous, current) =>
          previous.tags != current.tags || previous.filter != current.filter,
      child: BlocListener<ThreadBloc, ThreadState>(
        listener: (context, state) {
          // Reschedule mark as read when new notes are synced
          _scheduleMarkAsRead();
        },
        listenWhen: (previous, current) =>
            previous.notes != current.notes && current.thread.unread,
        child: BlocListener<ThreadBloc, ThreadState>(
          listener: (context, state) {
            // Focus NoteEditor when thread changes
            // (InfiniteListSelector is keyed by thread.id, so it creates a fresh controller)
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _noteEditorKey.currentState?.focus();
            });
          },
          listenWhen: (previous, current) =>
              previous.thread.id != current.thread.id,
          child: BlocBuilder<ThreadBloc, ThreadState>(
            builder: (context, state) {
              return _buildContent(context, state);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ThreadState state) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutStateForPanels) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              if (ModalProvider.tryDismissTopModal(context)) return;
              final provider =
                  ActivityPanelControllerProvider.maybeOf(context);
              if (provider != null && provider.tryCloseSearch()) return;
              if (!layoutStateForPanels.multiPanel) {
                context.run(ChangeCurrentThread(null));
              }
            }
          },
          child: InfiniteListSelector(
            key: ValueKey('thread_list_${state.thread.id}'),
            reverse: true,
            builder: (context, listController) {
              // Register this ThreadPage with the global focus coordination provider
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final provider = ActivityPanelControllerProvider.maybeOf(
                  context,
                );
                provider?.registerActivityPanel(
                  listController: listController,
                  editorFocusCallback: () =>
                      _noteEditorKey.currentState?.focus(),
                );
              });

              // Use Focus with onKeyEvent instead of Shortcuts to allow Cmd-Up/Down to bubble
              return Focus(
                onKeyEvent: (node, event) {
                  // Only handle key down and repeat events
                  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                    return KeyEventResult.ignored;
                  }

                  // Check if any modifier keys are pressed
                  final hasModifiers =
                      HardwareKeyboard.instance.isMetaPressed ||
                      HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isShiftPressed ||
                      HardwareKeyboard.instance.isAltPressed;

                  // Handle Cmd+C / Ctrl+C to copy focused note content
                  if (event.logicalKey == LogicalKeyboardKey.keyC &&
                      (HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed) &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      !HardwareKeyboard.instance.isAltPressed) {
                    final focusedIndex = listController.focusedIndex;
                    if (focusedIndex != null) {
                      final note = _getNoteAtIndex(state, focusedIndex);
                      if (note != null &&
                          note.content != null &&
                          note.content!.trim().isNotEmpty) {
                        context.run(CopyNoteContent(note));
                        return KeyEventResult.handled;
                      }
                    }
                  }

                  // Only handle plain arrow keys/enter/escape (no modifiers)
                  // Cmd-Up/Down should bubble up to global PriorityPage handler
                  if (!hasModifiers) {
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      // Reversed list: moving up visually means higher index
                      listController.moveFocus(1);
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      // Reversed list: moving down visually means lower index
                      // If already at first item (index 0), focus the NoteEditor
                      if (listController.focusedIndex == 0) {
                        listController.clearFocus();
                        _noteEditorKey.currentState?.focus();
                      } else {
                        listController.moveFocus(-1);
                      }
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.enter) {
                      final focusedIndex = listController.focusedIndex;
                      if (focusedIndex != null) {
                        final note = _getNoteAtIndex(state, focusedIndex);
                        if (note != null) {
                          final threadBloc = context.read<ThreadBloc>();
                          context.run(
                            OpenFocusedItemActions(listController, (index) {
                              final note = _getNoteAtIndex(state, index);
                              if (note == null) return [];
                              return noteCommandGroups(
                                note,
                                activityBloc: threadBloc,
                              );
                            }),
                          );
                          return KeyEventResult.handled;
                        }
                      }
                    }
                    if (event.logicalKey == LogicalKeyboardKey.escape) {
                      // Cancel editing if active
                      final threadBloc = context.read<ThreadBloc>();
                      if (threadBloc.state.editingNote != null) {
                        threadBloc.setEditingNote(null);
                        _noteEditorKey.currentState?.focus();
                        return KeyEventResult.handled;
                      }
                      listController.clearFocus();
                      // Focus NoteEditor after clearing item focus
                      _noteEditorKey.currentState?.focus();
                      return KeyEventResult.handled;
                    }
                  }

                  // Let all other events (including Cmd-Up/Down) bubble up
                  return KeyEventResult.ignored;
                },
                child: CommandScope(
                  commands: [
                    StaticCommandGroup(
                      title: 'Thread: ${state.thread.displayTitle}',
                      commands: threadCommands(state.thread),
                    ),
                  ],
                  child: Scaffold(
                    scrollable: false,
                    translucent: true,
                    childPad: false,
                    body: Column(
                      children: [
                        if (state.threadNoteId != null)
                          _ThreadFilterBar(
                            threadNoteId: state.threadNoteId!,
                          ),
                        ...state.links.map(
                          (link) => _ThreadLinkRow(
                            link: link,
                            thread: state.thread,
                          ),
                        ),
                        Flexible(
                          flex: 1,
                          fit: FlexFit.tight,
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: context.isMultiPanel ? 20.0 : 0,
                            ),
                            child: _buildThreadList(
                              state,
                              listController,
                              context,
                            ),
                          ),
                        ),
                        if (state.search.isNotEmpty && !state.showAllNotes && state.notes.length < state.totalNoteCount)
                          _SearchFilterHint(
                            onShowAll: () => context
                                .read<ThreadBloc>()
                                .setShowAllNotes(true),
                          ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: Padding(
                            padding: EdgeInsets.only(
                              left: context.isMultiPanel ? 20.0 : 0,
                              right: context.isMultiPanel ? 20.0 : 0,
                              top: 8,
                              bottom: context.isMultiPanel
                                  ? 20.0
                                  : MediaQuery.viewPaddingOf(context).bottom,
                            ),
                            child: NoteEditor(
                              key: _noteEditorKey,
                              draft: state.draft,
                              flushToBottom: !layoutStateForPanels.multiPanel,
                            ),
                          ),
                        ),
                      ],
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

  int _getTotalItemCount(ThreadState state) {
    return state.notes.length;
  }

  Note? _getNoteAtIndex(ThreadState state, int index) {
    if (index >= 0 && index < state.notes.length) {
      return state.notes[index];
    }
    return null;
  }

  Widget _buildThreadList(
    ThreadState state,
    InfiniteListController listController,
    BuildContext context,
  ) {
    final totalItems = _getTotalItemCount(state);

    return InfiniteList(
      controller: listController,
      scrollController: ScrollControllerContext.of(context),
      count: totalItems,
      reverse: true,
      doneEnd: true,
      fetcher: (first, count) =>
          Future<void>.value(), // No pagination needed for ThreadPage
      builder: (context, index, focusNode, {reorderableIndex}) {
        return _buildItemAtIndex(
          state,
          index,
          focusNode,
          reorderableIndex: reorderableIndex,
        );
      },
    );
  }

  Widget _buildItemAtIndex(
    ThreadState state,
    int index,
    FocusNode focusNode, {
    int? reorderableIndex,
  }) {
    final note = _getNoteAtIndex(state, index);
    if (note != null) {
      return NoteWidget(
        note: note,
        selected: false, // No selection on ThreadPage
        dimmed: state.editingNote?.id == note.id,
        focusNode: focusNode,
        key: ValueKey(note.id),
        reorderableIndex: reorderableIndex,
        showAuthor: state.hasOtherAuthors,
      );
    }
    return const SizedBox.shrink();
  }
}

/// Thread filter badge bar, shown when viewing a note thread.
class _ThreadFilterBar extends StatelessWidget {
  const _ThreadFilterBar({required this.threadNoteId});

  final NoteId threadNoteId;

  @override
  Widget build(BuildContext context) {
    return FAnimatedTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) => DecoratedBox(
          decoration: BoxDecoration(
            color: context.theme.colors.background,
            border: Border(
              bottom: BorderSide(
                color: context.theme.colors.border,
                width: 0.5,
              ),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.contentPaddingH,
              vertical: 6,
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () =>
                      context.read<ThreadBloc>().setThreadFilter(null),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.basic,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colour.accentBackground,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            FontAwesomeIcons.reply,
                            size: 10,
                            color: context.colour.accent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Thread',
                            style: context.theme.typography.xs.copyWith(
                              color: context.colour.accent,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            PlotIcon.close,
                            size: 8,
                            color: context.colour.accent,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hint bar shown when notes are filtered by global search.
class _SearchFilterHint extends StatelessWidget {
  const _SearchFilterHint({required this.onShowAll});

  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.isMultiPanel ? 20.0 : context.contentPaddingH,
        vertical: 4,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Notes filtered by search.',
            style: context.theme.typography.xs.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onShowAll,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: Text(
                'Show all',
                style: context.theme.typography.xs.copyWith(
                  color: context.theme.colors.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact row for a thread link, pinned above the scrolling notes list.
/// Shows source logo + link title. Clicking opens the external item.
class _ThreadLinkRow extends StatefulWidget {
  const _ThreadLinkRow({required this.link, required this.thread});

  final Link link;
  final Thread thread;

  @override
  State<_ThreadLinkRow> createState() => _ThreadLinkRowState();
}

class _ThreadLinkRowState extends State<_ThreadLinkRow> {
  bool _hovered = false;

  /// Whether the current user has connected their account for this link's source.
  bool get _isUserConnected {
    final ptId = widget.link.createdBy;
    if (ptId == null) return true;
    final pt = PriorityTwist.fromCache(ptId);
    if (pt == null || !pt.isSource) return true;
    return pt.userConnected;
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final sourceUrl = link.sourceUrl;
    final connected = _isUserConnected;

    return FAnimatedTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) {
          final linkLogo = link.logoForBrightness(
            MediaQuery.platformBrightnessOf(context),
          );
          return GestureDetector(
            onTap: connected
                ? (sourceUrl != null
                    ? () {
                        try {
                          launchUrl(
                            Uri.parse(sourceUrl),
                            mode: LaunchMode.externalApplication,
                          );
                        } catch (_) {}
                      }
                    : null)
                : () {
                    final ptId = link.createdBy;
                    if (ptId == null) return;
                    final pt = PriorityTwist.fromCache(ptId);
                    if (pt == null) return;
                    ConnectConnectorAccount(pt).run(context);
                  },
            child: MouseRegion(
              cursor: connected && sourceUrl != null
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.theme.colors.background,
                  border: Border(
                    bottom: BorderSide(
                      color: context.theme.colors.border,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.isMultiPanel ? 20.0 : context.contentPaddingH,
                    vertical: 6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (linkLogo != null)
                            LogoImage(
                              url: linkLogo,
                              fallback: const Icon(PlotIcon.link, size: 14),
                            )
                          else
                            const Icon(PlotIcon.link, size: 14),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              link.title ?? '',
                              style: context.theme.typography.sm.copyWith(
                                color: _hovered
                                    ? context.theme.colors.foreground
                                    : context.theme.colors.foreground.withValues(
                                        alpha: 0.7,
                                      ),
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          if (connected) ...[
                            if (link.getTypeConfig()?.supportsAssignee == true) ...[
                              const SizedBox(width: 8),
                              _LinkAssigneeBadge(
                                link: link,
                                priorityId: widget.thread.priority.id,
                              ),
                            ],
                            if (link.statusLabel != null) ...[
                              const SizedBox(width: 8),
                              _LinkStatusBadge(link: link),
                            ],
                            if (link.actions != null)
                              for (final action in link.actions!
                                  .whereType<ConferencingUserAction>()) ...[
                                const SizedBox(width: 8),
                                _ConferencingButton(action: action),
                              ],
                            if (_hasMenuActions) ...[
                              const SizedBox(width: 8),
                              _ThreadLinkMenu(
                                link: link,
                                thread: widget.thread,
                              ),
                            ],
                          ],
                        ],
                      ),
                      if (!connected)
                        Padding(
                          padding: const EdgeInsets.only(left: 22, top: 2),
                          child: Text(
                            'Connect your account',
                            style: context.theme.typography.xs.copyWith(
                              color: context.theme.colors.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Show menu button if there are link actions or thread is an event.
  bool get _hasMenuActions {
    if (widget.thread.at != null) return true;
    final actions = widget.link.actions
        ?.where((a) => a.type != UserActionType.conferencing)
        .toList();
    if (actions == null || actions.isEmpty) return false;
    if (actions.length > 1) return true;
    // Single action that is not external
    return actions.first.type != UserActionType.external;
  }
}

/// Small badge showing the link's assignee name.
/// Tappable to change the assignee via a picker modal.
class _LinkAssigneeBadge extends StatelessWidget {
  const _LinkAssigneeBadge({required this.link, required this.priorityId});

  final Link link;
  final Uuid priorityId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _resolveAssigneeName(),
      builder: (context, snapshot) {
        final label = snapshot.data ?? 'Unassigned';
        return FButton(
          style: FButtonStyle.secondary(
            (style) => style.copyWith(
              contentStyle: (cs) => cs.copyWith(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              ),
            ),
          ),
          onPress: () => _showAssigneePicker(context),
          child: Text(
            label,
            style: context.theme.typography.xs.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
        );
      },
    );
  }

  Future<String> _resolveAssigneeName() async {
    final assigneeId = link.assigneeId;
    if (assigneeId == null) return 'Unassigned';
    try {
      final actor = await Actor.getOne(assigneeId);
      return actor.nameOrEmail;
    } catch (_) {
      return 'Unassigned';
    }
  }

  Future<void> _showAssigneePicker(BuildContext context) async {
    final result = await SelectModal.open<_AssigneeOption>(
      context,
      items: (search) async {
        final actors = await Actor.get(
          priorityId: priorityId,
          search: search,
          types: [ActorType.user, ActorType.contact],
          limit: 50,
        );
        return [
          SelectGroup(
            items: [
              const _AssigneeOption(null, 'Unassigned', null),
              ...actors.map(
                (a) => _AssigneeOption(a.id, a.nameOrEmail, a.email),
              ),
            ],
          ),
        ];
      },
      itemBuilder: (option, _) {
        final isSelected = option.id == link.assigneeId;
        return ListTile(
          title: option.name,
          subtitle: (option.id != null &&
                  option.email != null &&
                  option.email != option.name)
              ? option.email
              : null,
          leadingBuilder: (isHovered, hasFocus) => Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: isSelected
                ? Icon(PlotIcon.done, size: 14, color: context.theme.colors.primary)
                : const SizedBox(width: 14),
          ),
          disableInternalHover: true,
        );
      },
      selectedValue: link.assigneeId != null
          ? _AssigneeOption(link.assigneeId!, '', null)
          : const _AssigneeOption(null, 'Unassigned', null),
      prompt: 'Assign to',
    );

    if (!result.present || !context.mounted) return;
    final newId = result.value.id;
    if (newId != link.assigneeId) {
      await Link.updateAssignee(link, newId);
    }
  }
}

/// Option for the assignee picker — equality based on actor id.
class _AssigneeOption {
  const _AssigneeOption(this.id, this.name, this.email);

  final ActorId? id;
  final String name;
  final String? email;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _AssigneeOption && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Small badge showing the link's status label.
/// Tappable when multiple statuses are available.
class _LinkStatusBadge extends StatelessWidget {
  const _LinkStatusBadge({required this.link});

  final Link link;

  @override
  Widget build(BuildContext context) {
    final typeConfig = link.getTypeConfig();
    final statuses = typeConfig?.statuses;
    final canChange = statuses != null && statuses.length > 1;
    final label = link.statusLabel ?? link.status ?? '';
    final currentStatus = statuses?.where((s) => s.status == link.status).firstOrNull;
    final statusTag = currentStatus?.tag != null ? Tag.get(id: currentStatus!.tag!) : null;

    return FButton(
      style: FButtonStyle.secondary(
        (style) => style.copyWith(
          contentStyle: (cs) => cs.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          ),
        ),
      ),
      onPress: canChange
          ? () => _showStatusPicker(context, link, statuses)
          : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (statusTag != null) ...[
            Icon(statusTag.icon, size: 12, color: context.theme.colors.mutedForeground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: context.theme.typography.xs.copyWith(
              color: context.theme.colors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _showStatusPicker(
    BuildContext context,
    Link link,
    List<LinkStatus> statuses,
  ) async {
    final result = await SelectModal.open<String>(
      context,
      items: (search) async => [
        SelectGroup(items: statuses.map((s) => s.status).toList()),
      ],
      itemBuilder: (status, _) {
        final s = statuses.firstWhere((ls) => ls.status == status);
        return ListTile(
          title: s.label,
          leadingBuilder: (isHovered, hasFocus) => Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: s.status == link.status
                ? Icon(PlotIcon.done, size: 14, color: context.theme.colors.primary)
                : const SizedBox(width: 14),
          ),
          disableInternalHover: true,
        );
      },
      selectedValue: link.status,
      prompt: 'Set status',
    );

    if (!result.present || !context.mounted) return;
    final selected = result.value;
    if (selected != link.status) {
      await Link.updateStatus(link, selected);
    }
  }
}

/// Icon button that launches a conferencing URL (Google Meet, Zoom, etc.).
class _ConferencingButton extends StatelessWidget {
  const _ConferencingButton({required this.action});

  final ConferencingUserAction action;

  @override
  Widget build(BuildContext context) {
    final tooltip = switch (action.provider) {
      ConferencingProvider.googleMeet => 'Join Google Meet',
      ConferencingProvider.zoom => 'Join on Zoom',
      ConferencingProvider.microsoftTeams => 'Join on Teams',
      ConferencingProvider.webex => 'Join Webex',
      ConferencingProvider.other => 'Join Meeting',
    };

    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: GestureDetector(
        onTap: () {
          try {
            launchUrl(
              Uri.parse(action.url),
              mode: LaunchMode.externalApplication,
            );
          } catch (_) {}
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              PlotIcon.video,
              size: 14,
              color: context.theme.colors.foreground.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// "..." menu button for link row actions.
class _ThreadLinkMenu extends StatefulWidget {
  const _ThreadLinkMenu({required this.link, required this.thread});

  final Link link;
  final Thread thread;

  @override
  State<_ThreadLinkMenu> createState() => _ThreadLinkMenuState();
}

class _ThreadLinkMenuState extends State<_ThreadLinkMenu> {
  final _controller = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final style = context.theme.popoverMenuStyle;

    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (context) {
        final buttonBox = this.context.findRenderObject() as RenderBox;
        final overlay =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final position = buttonBox.localToGlobal(
          Offset(buttonBox.size.width, buttonBox.size.height),
          ancestor: overlay,
        );

        return Positioned(
          top: position.dy,
          right: overlay.size.width - position.dx,
          child: TapRegion(
            onTapOutside: (_) => _controller.hide(),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: style.maxWidth),
              child: DecoratedBox(
                decoration: style.decoration,
                child: FInheritedItemData(
                  child: FItemGroup.merge(
                    style: style.itemGroupStyle,
                    divider: FItemDivider.full,
                    children: [FItemGroup(children: _buildMenuItems())],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      child: GestureDetector(
        onTap: () {
          if (_controller.isShowing) {
            _controller.hide();
          } else {
            _controller.show();
          }
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Icon(
              PlotIcon.more,
              size: 14,
              color: context.theme.colors.foreground.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  List<FItem> _buildMenuItems() {
    final items = <FItem>[];
    if (widget.thread.at != null) {
      items.add(FItem(
        title: const Text('Reschedule'),
        onPress: () {
          _controller.hide();
          RescheduleEvent(widget.thread).run(context);
        },
      ));
    }
    final actions = (widget.link.actions ?? [])
        .where((a) => a.type != UserActionType.conferencing)
        .toList();
    items.addAll(actions.map((action) {
      switch (action.type) {
        case UserActionType.external:
          final ext = action as ExternalUserAction;
          return FItem(
            title: Text(ext.title),
            onPress: () {
              _controller.hide();
              try {
                launchUrl(
                  Uri.parse(ext.url),
                  mode: LaunchMode.externalApplication,
                );
              } catch (_) {}
            },
          );
        case UserActionType.conferencing:
          final conf = action as ConferencingUserAction;
          final confTitle = switch (conf.provider) {
            ConferencingProvider.googleMeet => 'Join Google Meet',
            ConferencingProvider.zoom => 'Join on Zoom',
            ConferencingProvider.microsoftTeams => 'Join on Teams',
            ConferencingProvider.webex => 'Join Webex',
            ConferencingProvider.other => 'Join Meeting',
          };
          return FItem(
            title: Text(confTitle),
            onPress: () {
              _controller.hide();
              try {
                launchUrl(
                  Uri.parse(conf.url),
                  mode: LaunchMode.externalApplication,
                );
              } catch (_) {}
            },
          );
        default:
          return FItem(title: const Text('Action'));
      }
    }).toList());
    return items;
  }
}
