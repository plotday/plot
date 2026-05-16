import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:plot/router.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/edit_link_modal.dart';
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
    : threadId = ThreadId.tryFromShortString(threadIdString);

  final ThreadId? threadId;

  @override
  Widget wrappedRoute(BuildContext context) {
    final threadId = this.threadId;
    if (threadId == null) {
      // Invalid base58 thread id (e.g. /p/<pid>/login). Redirect to home
      // instead of crashing in the parser.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        context.router.replaceAll([const RootRoute()]);
      });
      return const SizedBox.shrink();
    }
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

  // Store reference to PriorityBloc for cleanup in dispose
  PriorityBloc? _priorityBloc;

  // The thread ID this page is showing, for conditional cleanup in dispose
  ThreadId? _threadId;

  // Timer for delayed read marking
  Timer? _markReadTimer;

  // Flag to ensure setActivity is only called once on initial load
  bool _hasSetInitialActivity = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Save references during a safe lifecycle method
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
    _priorityBloc = context.read<PriorityBloc>();
    _threadId = context.read<ThreadBloc>().state.thread.id;
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
    // Clear thread from PriorityBloc if it still shows this page's thread.
    // This handles browser back/gesture back which bypass PopScope.
    // Guard: skip if navigating thread-to-thread (bloc already updated).
    if (_priorityBloc?.state.thread?.id == _threadId) {
      _priorityBloc?.setThread(null);
    }
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
        thread
            .copyWith(unread: false, readAt: Value(thread.contentTimestamp))
            .save();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Force forui defaults with an explicit `decoration: TextDecoration.none`
    // so Text widgets in this subtree never inherit MaterialApp's internal
    // `_errorTextStyle` (yellow double-underline) when their nearest
    // DefaultTextStyle comes from a Material-injected ancestor instead of
    // the app.dart route-level wrap. See app.dart for the broader story.
    return DefaultTextStyle(
      style: context.theme.typography.md.copyWith(
        color: context.theme.colors.foreground,
        decoration: TextDecoration.none,
      ),
      child: BlocListener<ThreadBloc, ThreadState>(
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
      ),
    );
  }

  Widget _buildContent(BuildContext context, ThreadState state) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutStateForPanels) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            // If the on-screen keyboard is up, dismiss it before
            // navigating away. Matches the platform back-gesture
            // convention on Android/iOS.
            if (MediaQuery.viewInsetsOf(context).bottom > 0) {
              FocusManager.instance.primaryFocus?.unfocus();
              return;
            }
            if (ModalProvider.tryDismissTopModal(context)) return;
            final provider = ActivityPanelControllerProvider.maybeOf(context);
            if (provider != null && provider.tryCloseSearch()) return;
            if (!layoutStateForPanels.multiPanel) {
              context.run(ChangeCurrentThread(null));
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

                  // Handle Cmd+D / Ctrl+D to toggle start/finish the open thread
                  if (event.logicalKey == LogicalKeyboardKey.keyD &&
                      (HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed) &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      !HardwareKeyboard.instance.isAltPressed) {
                    final thread = context.read<PriorityBloc>().state.thread;
                    if (thread != null) {
                      if (thread.todo) {
                        FinishThread(thread).run(context);
                      } else {
                        StartThread(thread).run(context);
                      }
                      return KeyEventResult.handled;
                    }
                  }

                  // Handle Cmd+Shift+D / Ctrl+Shift+D to schedule the open thread
                  if (event.logicalKey == LogicalKeyboardKey.keyD &&
                      (HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed) &&
                      HardwareKeyboard.instance.isShiftPressed &&
                      !HardwareKeyboard.instance.isAltPressed) {
                    final thread = context.read<PriorityBloc>().state.thread;
                    if (thread != null) {
                      PickScheduleThread(thread).run(context);
                      return KeyEventResult.handled;
                    }
                  }

                  // Handle Cmd+Backspace / Ctrl+Backspace to archive the open thread
                  if (event.logicalKey == LogicalKeyboardKey.backspace &&
                      (HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed) &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      !HardwareKeyboard.instance.isAltPressed) {
                    final thread = context.read<PriorityBloc>().state.thread;
                    if (thread != null) {
                      ArchiveThread(thread).run(context);
                      return KeyEventResult.handled;
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
                  commandsBuilder: () {
                    final focusedIndex = listController.focusedIndex;
                    final note = focusedIndex != null
                        ? _getNoteAtIndex(state, focusedIndex)
                        : null;
                    final threadBloc = context.read<ThreadBloc>();
                    final priorityBloc = context.read<PriorityBloc?>();
                    return [
                      if (note != null)
                        ...noteCommandGroups(note, activityBloc: threadBloc),
                      ...threadCommandGroupsSync(
                        state.thread,
                        priorityBloc: priorityBloc,
                      ),
                    ];
                  },
                  listenable: listController,
                  child: Scaffold(
                    scrollable: false,
                    translucent: true,
                    childPad: false,
                    body: LayoutBuilder(
                      builder: (context, panelConstraints) {
                        return Column(
                          children: [
                            // In multi-panel mode the unified header has no
                            // thread-specific buttons. Surface them here at
                            // the top of the thread squircle so they stay
                            // pinned while the notes list scrolls below.
                            if (layoutStateForPanels.multiPanel)
                              _ThreadActionsRow(thread: state.thread),
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
                                child: ScrollEdgeFade(
                                  background: context.colour.background,
                                  child: _buildThreadList(
                                    state,
                                    listController,
                                    context,
                                  ),
                                ),
                              ),
                            ),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: panelConstraints.maxHeight * 0.4,
                              ),
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: context.isMultiPanel ? 20.0 : 0,
                                  right: context.isMultiPanel ? 20.0 : 0,
                                  top: 8,
                                  // NoteEditor's `flushToBottom` already absorbs
                                  // the bottom safe-area inset. Adding it here
                                  // too produced a doubled gap below the action
                                  // buttons on iOS.
                                  bottom: context.isMultiPanel ? 20.0 : 0,
                                ),
                                child: NoteEditor(
                                  key: _noteEditorKey,
                                  draft: state.draft,
                                  flushToBottom:
                                      !layoutStateForPanels.multiPanel,
                                  viewerMode: state.thread.isReadOnly,
                                ),
                              ),
                            ),
                          ],
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
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      fetcher: (first, count) =>
          Future<void>.value(), // No pagination needed for ThreadPage
      itemKey: (index) {
        final note = _getNoteAtIndex(state, index);
        return note?.id.toString() ?? 'empty_$index';
      },
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
        searchHighlight: state.search.isNotEmpty ? state.search : null,
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
    return FTheme(
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
                  onTap: () => context.read<ThreadBloc>().setThreadFilter(null),
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
    final pt = TwistInstance.fromCache(ptId);
    if (pt == null || !pt.isSource) return true;
    return pt.userConnected;
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final sourceUrl = link.sourceUrl;
    final connected = _isUserConnected;

    return FTheme(
      data: darkenTheme(context, context.theme, context.colour, steps: 2),
      child: Builder(
        builder: (context) {
          final linkLogo = link.logoForBrightness(context.colour.brightness);
          return GestureDetector(
            onTap: connected
                ? (sourceUrl != null
                      ? () async {
                          final uri = Uri.tryParse(sourceUrl);
                          if (uri == null) return;
                          await launchUrl(
                            uri,
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      : null)
                : () {
                    final ptId = link.createdBy;
                    if (ptId == null) return;
                    final pt = TwistInstance.fromCache(ptId);
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
                    horizontal: context.isMultiPanel
                        ? 20.0
                        : context.contentPaddingH,
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
                                    : context.theme.colors.foreground
                                          .withValues(alpha: 0.7),
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          if (connected) ...[
                            if (link.getTypeConfig()?.supportsAssignee ==
                                true) ...[
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
                              for (final action
                                  in link.actions!
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

  /// Show menu button if there are link actions, the thread is an event,
  /// or the link is user-editable (Edit / Unpin items are always
  /// available on links not owned by a connector).
  bool get _hasMenuActions {
    if (widget.thread.at != null) return true;
    final isUserEditable =
        widget.link.sourceUrl != null && widget.link.getTypeConfig() == null;
    if (isUserEditable) return true;
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
          variant: FButtonVariant.secondary,
          style: FButtonStyleDelta.delta(
            contentStyle: FButtonContentStyleDelta.delta(
              padding: EdgeInsetsGeometryDelta.value(
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          search: search,
          types: [ActorType.user, ActorType.contact],
          limit: 50,
          inviteable: true,
          primary: true,
        );
        // Sort self actors to the top, preserving existing depth-based order
        actors.sort((a, b) {
          if (a.self != b.self) return a.self ? -1 : 1;
          return 0;
        });
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
          subtitle:
              (option.id != null &&
                  option.email != null &&
                  option.email != option.name)
              ? option.email
              : null,
          leadingBuilder: (isHovered, hasFocus) => Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: isSelected
                ? Icon(
                    PlotIcon.done,
                    size: 14,
                    color: context.theme.colors.primary,
                  )
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
      identical(this, other) || other is _AssigneeOption && id == other.id;

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
    final currentStatus = statuses
        ?.where((s) => s.status == link.status)
        .firstOrNull;
    final statusTag = currentStatus?.tag != null
        ? Tag.get(id: currentStatus!.tag!)
        : null;

    return FButton(
      variant: FButtonVariant.secondary,
      style: FButtonStyleDelta.delta(
        contentStyle: FButtonContentStyleDelta.delta(
          padding: EdgeInsetsGeometryDelta.value(
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            Icon(
              statusTag.icon,
              size: 12,
              color: context.theme.colors.mutedForeground,
            ),
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
                ? Icon(
                    PlotIcon.done,
                    size: 14,
                    color: context.theme.colors.primary,
                  )
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
        onTap: () async {
          final uri = Uri.tryParse(action.url);
          if (uri == null) return;
          await launchUrl(uri, mode: LaunchMode.externalApplication);
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
      items.add(
        FItem(
          title: const Text('Reschedule'),
          onPress: () {
            _controller.hide();
            RescheduleEvent(widget.thread).run(context);
          },
        ),
      );
    }
    final actions = (widget.link.actions ?? [])
        .where((a) => a.type != UserActionType.conferencing)
        .toList();
    items.addAll(
      actions.map((action) {
        switch (action.type) {
          case UserActionType.external:
            final ext = action as ExternalUserAction;
            return FItem(
              title: Text(ext.title),
              onPress: () async {
                _controller.hide();
                final uri = Uri.tryParse(ext.url);
                if (uri == null) return;
                await launchUrl(uri, mode: LaunchMode.externalApplication);
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
              onPress: () async {
                _controller.hide();
                final uri = Uri.tryParse(conf.url);
                if (uri == null) return;
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
            );
          default:
            return FItem(title: const Text('Action'));
        }
      }).toList(),
    );
    // User-editable links (those backed by a sourceUrl from outside a
    // connector context) get Edit + Unpin. Connector-managed links (with a
    // type config) keep their source as the authority — editing them in
    // Plot would lose data on the next sync.
    final canEditLink =
        widget.link.sourceUrl != null && widget.link.getTypeConfig() == null;
    if (canEditLink) {
      items.add(
        FItem(
          title: const Text('Edit link'),
          onPress: () {
            _controller.hide();
            _editLink();
          },
        ),
      );
      items.add(
        FItem(
          title: const Text('Unpin'),
          onPress: () {
            _controller.hide();
            _unpinLink();
          },
        ),
      );
    }
    return items;
  }

  Future<void> _editLink() async {
    final link = widget.link;
    final initialTitle = link.title ?? '';
    final initialUrl = link.sourceUrl ?? '';
    final result = await EditLinkModal(
      initialTitle: initialTitle,
      initialUrl: initialUrl,
    ).run(context);
    if (result == null) return;
    if (result.title == initialTitle && result.url == initialUrl) return;
    await Link.updateTitleAndUrl(
      link,
      title: result.title.isEmpty ? null : result.title,
      url: result.url,
    );
  }

  Future<void> _unpinLink() async {
    await Link.unpinFromThread(widget.link);
  }
}

/// Pinned action row inside the thread squircle (multi-panel only).
///
/// In multi-panel mode the unified header carries no thread-specific
/// buttons — they live here, fixed at the top of the squircle so the
/// notes scroll list underneath can fade against its top edge cleanly.
///
/// Start of the row: tag toggles, Todo/Finish, Schedule.
/// End of the row: Edit, Share, "…" menu (thread-level commands only).
class _ThreadActionsRow extends StatelessWidget {
  const _ThreadActionsRow({required this.thread});

  final Thread thread;

  @override
  Widget build(BuildContext context) {
    final threadColor = context.colour.colours.fromTheme(
      thread.priority.displayColor,
    );
    final isTodo = thread.todo;
    final isScheduled = isTodo && thread.isFuture;
    final readOnly = thread.isReadOnly;

    final Widget todoButton;
    if (!isTodo) {
      todoButton = Button.icon(
        CommandWrapper(StartThread(thread), icon: Value(PlotIcon.addTodo)),
      );
    } else {
      todoButton = Button.icon(
        CommandWrapper(
          FinishThread(thread),
          icon: Value(FontAwesomeIcons.circle),
          hoverIcon: Value(FontAwesomeIcons.circleCheck),
          title: 'Finish',
        ),
        selected: true,
        selectedColor: threadColor,
      );
    }

    final scheduleButton = Button.icon(
      CommandWrapper(
        PickScheduleThread(thread),
        icon: Value(PlotIcon.schedule),
        title: 'Schedule',
      ),
      selected: isScheduled,
      selectedColor: threadColor,
    );

    // Surface up to three active addable tag toggles (Reply is included
    // only when the current actor already replied — same logic as the
    // unified header's previous in-place tags row).
    final activeTagButtons = thread.tags.keys
        .where((tag) {
          if (tag == Tag.todo) return false;
          if (!tag.addable) return false;
          if (tag == Tag.reply) {
            return thread.tags[tag]?.contains(Base.actorId) ?? false;
          }
          return true;
        })
        .take(3)
        .map((tag) => Button.icon(ToggleThreadTag(thread, tag)))
        .toList();

    final startGroup = <Widget>[
      ...activeTagButtons,
      todoButton,
      scheduleButton,
    ];

    final endGroup = <Widget>[
      if (!readOnly) Button.icon(EditThread(thread)),
      if (!readOnly) SharedCommandButton(thread: thread),
      Button.icon(_buildThreadMenuCommand(thread)),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colour.headerBackground,
        border: Border(
          bottom: BorderSide(color: context.theme.colors.border, width: 1),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.isMultiPanel
              ? 20.0
              : context.contentPaddingH,
          vertical: context.theme.spacing.xs,
        ),
        child: Row(children: [...startGroup, const Spacer(), ...endGroup]),
      ),
    );
  }

  Command _buildThreadMenuCommand(Thread thread) {
    return ShowCommands(
      title: 'Menu',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final priorityBloc = context.read<PriorityBloc?>();
        final groups = await threadCommandGroups(
          thread,
          priorityBloc: priorityBloc,
        );
        return Commands(groups: groups);
      },
    );
  }
}
