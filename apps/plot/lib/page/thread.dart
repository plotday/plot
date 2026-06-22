import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/router.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/thread_carousel_nav.dart';
import 'package:plot/widget/thread_carousel.dart';
import 'package:plot/widget/thread_preview.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/state/priority.dart';

import 'package:plot/state/thread.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/util/note_initial_view.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/thread_assignee.dart';
import 'package:plot/widget/thread_header_notifier.dart';
import 'package:plot/widget/primary_link_header_actions.dart';
import 'package:plot/widget/thread_sharing.dart';
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

    if (!shouldUseThreadCarousel(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
    )) {
      return _buildLiveThread(threadId);
    }

    // iOS / Android: page through the feed's threads in a swipe carousel. The
    // thread list comes from the same feed the thread was opened from, so the
    // swipe order matches the keyboard up/down arrows. Swiping promotes a
    // thread via setThread only (no route push), so the back stack stays a
    // single ThreadRoute and Back returns to the list. When the thread is not
    // in the feed (deep link / search-filtered), the carousel renders a single
    // inert page — today's behavior, no swipe.
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        final centerId = state.thread?.id ?? threadId;
        final threads = feedThreads(state.activityFeedItems);
        final index = threads.indexWhere((t) => t.id == centerId);
        return ThreadCarousel(
          centerThreadId: centerId,
          threads: threads,
          initialIndex: index,
          centerBuilder: _buildLiveThread,
          previewBuilder: (thread) => ThreadPreview(thread: thread),
          onThreadChanged: (thread) =>
              context.read<PriorityBloc>().setThread(thread),
          reserveLeftEdgeBackZone:
              !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS,
        );
      },
    );
  }

  /// Builds the single live thread view for [id] — the existing thread page,
  /// unchanged. Used directly on desktop/web and as the carousel center on
  /// mobile. Keyed by id at the call site (see [ThreadCarousel]) so only one
  /// ThreadBloc is ever mounted and it is preserved across feed rebuilds.
  Widget _buildLiveThread(ThreadId id) {
    return ThreadBlocProvider(
      threadId: id,
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

  // Snapshot of the thread's read state captured when the page opened,
  // BEFORE the 750ms mark-as-read timer resets readAt. Drives which notes
  // start expanded and which note the list scrolls to. See
  // util/note_initial_view.dart.
  DateTime? _initialReadAt;
  bool _initialThreadUnread = false;
  bool _readSnapshotTaken = false;

  // Initial scroll: the note whose top the list scrolls to on open, tagged
  // with this GlobalKey so its render object can be located. Computed once
  // when notes first arrive; the scroll runs once post-layout.
  final GlobalKey _scrollTargetKey = GlobalKey();
  int? _scrollTargetIndex;
  bool _initialScrollScheduled = false;

  // Owned by this page and passed to the note list's InfiniteList so the
  // initial-scroll logic can drive it. (ScrollControllerContext has no
  // provider in the app, so it cannot supply one.)
  final ScrollController _scrollController = ScrollController();

  // Hide the note list until the initial scroll target is first revealed, so
  // the pre-scroll bottom frame never flashes past on open. Only gated when a
  // scroll target exists; a null target keeps the natural bottom position
  // (offset 0), which needs no repositioning and so no gating.
  bool _initialScrollSettled = false;

  // Swipe carousel: preserve the note-scroll position across swipe-away/back.
  // When this page sits inside a ThreadCarousel, [_scrollCache] carries the
  // per-thread saved offset; we restore it on first layout (instead of the
  // scroll-to-unread target) and save the latest offset on dispose.
  // [_restoringCachedOffset] gates the list hidden until the restore lands, so
  // the bottom frame doesn't flash. All null/false off-carousel (desktop/web),
  // so the normal scroll-to-unread behavior is unchanged there.
  CarouselScrollCache? _scrollCache;
  double? _lastNoteScrollOffset;
  bool _restoringCachedOffset = false;

  // While true, the scroll target is re-pinned to the viewport top whenever
  // the list's scroll metrics change — e.g. async network images below the
  // target finish loading and grow their notes, which would otherwise push
  // the target off the top. Disarmed on the first user scroll or after a
  // short settle window. See _finishInitialScroll / _pinScrollTargetToTop.
  bool _repinScrollTarget = false;
  Timer? _repinTimer;

  // Flag to ensure setActivity is only called once on initial load
  bool _hasSetInitialActivity = false;

  @override
  void initState() {
    super.initState();
    // Track the latest note-scroll offset so it can be saved (for the swipe
    // carousel) in dispose, after the Scrollable has already detached.
    _scrollController.addListener(_recordScrollOffset);
  }

  void _recordScrollOffset() {
    if (_scrollController.hasClients) {
      _lastNoteScrollOffset = _scrollController.offset;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Save references during a safe lifecycle method
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _headerNotifier = ThreadHeaderNotifierProvider.read(context);
    _priorityBloc = context.read<PriorityBloc>();
    // Carousel scroll-offset cache (null off-carousel). Registers a dependency
    // but the cache never notifies, so this resolves once.
    _scrollCache = CarouselScrollCache.maybeOf(context);
    final thread = context.read<ThreadBloc>().state.thread;
    _threadId = thread.id;
    // Snapshot read state once, before _scheduleMarkAsRead's timer resets it.
    if (!_readSnapshotTaken) {
      _readSnapshotTaken = true;
      _initialReadAt = thread.readAt;
      _initialThreadUnread = thread.unread;
    }
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
        context.read<ThreadBloc>().updateReactionFilter([]);
        context.read<ThreadBloc>().setThreadFilter(null);
      },
      tags: state.tags,
      filter: state.filter,
      reactions: state.reactions,
      reactionFilter: state.reactionFilter,
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
    _repinTimer?.cancel();
    // Save the note-scroll position so swiping back to this thread (in the
    // carousel) restores where the user was reading. No-op off-carousel.
    if (_scrollCache != null &&
        _threadId != null &&
        _lastNoteScrollOffset != null) {
      _scrollCache!.save(_threadId!, _lastNoteScrollOffset!);
    }
    _scrollController.removeListener(_recordScrollOffset);
    _scrollController.dispose();
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

  /// Marks the thread read as soon as it is opened. Deferred to the next
  /// macrotask (not 750ms) so the unread indicator clears on open rather
  /// than lingering until the thread is unfocused. The zero-delay timer
  /// also runs after the post-frame `setThread` that creates the
  /// sticky-unread overlay, so the read row is still pinned at its
  /// pre-read position (the dot just clears). Cancelled in [dispose] so an
  /// instantaneous open-and-close (sub-frame) doesn't mark it read.
  void _scheduleMarkAsRead() {
    // Cancel any existing timer
    _markReadTimer?.cancel();

    _markReadTimer = Timer(Duration.zero, () {
      final thread = context.read<ThreadBloc>().state.thread;
      if (thread.unread) {
        thread
            .copyWith(unread: false, readAt: Value(thread.contentTimestamp))
            .save();
      }
    });
  }

  /// Scrolls the (reverse) note list so the scroll-target note's top aligns
  /// to the viewport top. The target may not be laid out yet (it sits above
  /// the initial bottom view), so we nudge toward older notes a page at a
  /// time until it builds, then reveal it precisely. Bounded retries. Every
  /// terminal branch calls [_finishInitialScroll], so the list is always
  /// revealed — even when the target never builds — and never stays blank.
  void _revealScrollTarget({required int attempt}) {
    final controller = _scrollController;
    if (!controller.hasClients) {
      if (attempt >= 10) {
        _finishInitialScroll(success: false);
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealScrollTarget(attempt: attempt + 1);
      });
      return;
    }

    if (_pinScrollTargetToTop()) {
      _finishInitialScroll(success: true);
      return;
    }

    // Target not built yet: scroll toward older notes (up, increasing offset
    // in a reverse list) by a page and retry.
    if (attempt >= 10) {
      _finishInitialScroll(success: false);
      return;
    }
    final next = (controller.offset + controller.position.viewportDimension)
        .clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        )
        .toDouble();
    if (next <= controller.offset) {
      _finishInitialScroll(success: false); // already at top; cannot reveal
      return;
    }
    controller.jumpTo(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealScrollTarget(attempt: attempt + 1);
    });
  }

  /// Aligns the scroll-target note's top edge to the viewport top, if that
  /// note is currently laid out. Returns true when the target was found (and
  /// pinned), false otherwise. Safe to call repeatedly: it no-ops when the
  /// offset is already correct, so re-pinning on layout changes cannot loop.
  bool _pinScrollTargetToTop() {
    final controller = _scrollController;
    if (!controller.hasClients) return false;
    final renderObject = _scrollTargetKey.currentContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) return false;
    final viewport = RenderAbstractViewport.of(renderObject);
    // alignment 1.0: in the reverse (AxisDirection.up) list the note's top
    // edge (its trailing edge) aligns to the viewport's trailing edge — i.e.
    // the note's top sits at the visual top of the viewport.
    final reveal = viewport
        .getOffsetToReveal(renderObject, 1.0)
        .offset
        .clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        )
        .toDouble();
    if ((reveal - controller.offset).abs() > 0.5) {
      controller.jumpTo(reveal);
    }
    return true;
  }

  /// Terminates the initial-scroll sequence: reveals the list (hidden until
  /// now to mask the pre-scroll frame) and, on success, arms re-pinning so the
  /// target stays at the top while async images below it load and grow. The
  /// re-pin window is disarmed on the first user scroll (see the
  /// [UserScrollNotification] listener in [_buildThreadList]) or after a short
  /// timeout.
  void _finishInitialScroll({required bool success}) {
    if (!_initialScrollSettled && mounted) {
      setState(() => _initialScrollSettled = true);
    }
    if (!success) return;
    _repinScrollTarget = true;
    _repinTimer?.cancel();
    _repinTimer = Timer(const Duration(seconds: 4), () {
      _repinScrollTarget = false;
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
          // Update header notifier when tags/filter/reactions change
          _headerNotifier?.updateTags(state.tags, state.filter);
          _headerNotifier?.updateReactions(
            state.reactions,
            state.reactionFilter,
          );
        },
        listenWhen: (previous, current) =>
            previous.tags != current.tags ||
            previous.filter != current.filter ||
            previous.reactions != current.reactions ||
            previous.reactionFilter != current.reactionFilter,
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
    // One-time: once notes exist, pick the scroll target and (if any) scroll
    // to its top after layout. Computing the index here (before the item
    // builders run) ensures the target note gets _scrollTargetKey on its
    // first build.
    if (!_initialScrollScheduled && state.notes.isNotEmpty) {
      _initialScrollScheduled = true;
      // In the swipe carousel, restore the saved offset for a thread the user
      // is swiping back to, instead of the scroll-to-unread target.
      final cachedOffset =
          _threadId == null ? null : _scrollCache?.offsetFor(_threadId!);
      if (cachedOffset != null) {
        _restoringCachedOffset = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_scrollController.hasClients) {
            final pos = _scrollController.position;
            _scrollController.jumpTo(
              cachedOffset.clamp(pos.minScrollExtent, pos.maxScrollExtent),
            );
          }
          // Reveal the list (it was gated hidden); no re-pin for a restore.
          _finishInitialScroll(success: false);
        });
      } else {
        _scrollTargetIndex = initialScrollTargetIndex(
          state.notes,
          threadUnread: _initialThreadUnread,
          readAt: _initialReadAt,
        );
        if (_scrollTargetIndex != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _revealScrollTarget(attempt: 0);
          });
        }
      }
    }

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

                  // ⌘D / Ctrl+D — toggle the active flag (Doing).
                  if (event.logicalKey == LogicalKeyboardKey.keyD &&
                      (HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed) &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      !HardwareKeyboard.instance.isAltPressed) {
                    final thread = context.read<PriorityBloc>().state.thread;
                    if (thread != null) {
                      ToggleThreadActive(thread).run(context);
                      return KeyEventResult.handled;
                    }
                  }

                  // ⌘⏎ / Ctrl+⏎ — finish the open thread (was ⌘D before
                  // the move-to-tab commands took it).
                  if (event.logicalKey == LogicalKeyboardKey.enter &&
                      (HardwareKeyboard.instance.isMetaPressed ||
                          HardwareKeyboard.instance.isControlPressed) &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      !HardwareKeyboard.instance.isAltPressed) {
                    final thread = context.read<PriorityBloc>().state.thread;
                    if (thread != null && thread.todo) {
                      FinishThread(thread).run(context);
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

                  // Only handle plain arrow keys/enter/escape (no modifiers)
                  // Cmd-Up/Down should bubble up to global PriorityPage handler
                  if (!hasModifiers) {
                    // When the NoteEditor has focus and content, arrow keys
                    // should stay in the editor (move the caret) rather than
                    // moving focus to other notes. On macOS the editor uses
                    // IME, which delivers arrow keys as moveUp:/moveDown:
                    // selectors and then bubbles the underlying key event
                    // out of SuperEditor (via sendKeyEventToMacOs); without
                    // this guard the bubble would hijack the caret motion.
                    final noteEditorState = _noteEditorKey.currentState;
                    final editorActive =
                        noteEditorState != null &&
                        noteEditorState.hasFocus &&
                        !noteEditorState.isEmpty;
                    if (editorActive &&
                        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                            event.logicalKey == LogicalKeyboardKey.arrowDown)) {
                      return KeyEventResult.ignored;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      // Reversed list: moving up visually means higher index.
                      // From no-focus, jump to the bottom-most note (index 0)
                      // rather than letting moveFocus fall back to a stale
                      // lastFocusedIndex left over from a prior selection.
                      if (listController.focusedIndex == null) {
                        listController.requestFocus(0);
                      } else {
                        listController.moveFocus(1);
                      }
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      // Reversed list: moving down visually means lower index.
                      // From no-focus (e.g. inside the editor), down stays
                      // in the editor instead of pulling focus into the list.
                      final focusedIndex = listController.focusedIndex;
                      if (focusedIndex == null) {
                        _noteEditorKey.currentState?.focus();
                      } else if (focusedIndex == 0) {
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
                        isPlotThread: Thread.isPlotThread(state.links),
                        sharingModel: Thread.resolveSharingModel(state.links),
                        openInLink: Thread.primaryLink(state.links),
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
                            Flexible(
                              flex: 1,
                              fit: FlexFit.tight,
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: context.isMultiPanel ? 20.0 : 0,
                                ),
                                child: LayoutBuilder(
                                  builder: (context, listConstraints) =>
                                      NotePanelMetrics(
                                        availableHeight:
                                            listConstraints.maxHeight,
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
    // Notes still loading on demand (not yet local, and none arrived): show a
    // delayed spinner so the list area isn't blank. The 100ms delay means it
    // never flashes when notes are already local — `notesLoaded` flips within
    // a frame in that case. The thread header, actions row, and composer keep
    // rendering around this (they're outside _buildThreadList).
    if (!state.notesLoaded && state.notes.isEmpty) {
      return const Center(child: DelayedSpinner());
    }

    final totalItems = _getTotalItemCount(state);

    final list = InfiniteList(
      controller: listController,
      scrollController: _scrollController,
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

    // Keep the initial scroll target pinned to the top while async content
    // settles. ScrollMetricsNotification fires when the list's content size
    // changes (e.g. a network image below the target finishes loading), which
    // in a bottom-anchored reverse list would otherwise push the target off
    // the top. UserScrollNotification means the user took over, so we stop.
    final gated = NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (_repinScrollTarget) {
          // Defer to after layout so getOffsetToReveal sees the new metrics.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _repinScrollTarget) _pinScrollTargetToTop();
          });
        }
        return false;
      },
      child: NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.direction != ScrollDirection.idle) {
            _repinScrollTarget = false;
            _repinTimer?.cancel();
          }
          return false;
        },
        child: list,
      ),
    );

    // Hide the list until the target is first revealed so the pre-scroll
    // bottom frame never flashes. Gate when there is a target to reveal, or a
    // cached carousel offset still being restored.
    final gateOpacity =
        (_scrollTargetIndex != null || _restoringCachedOffset) &&
                !_initialScrollSettled
            ? 0.0
            : 1.0;
    return Opacity(opacity: gateOpacity, child: gated);
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
        key: _scrollTargetIndex == index ? _scrollTargetKey : ValueKey(note.id),
        reorderableIndex: reorderableIndex,
        showAuthor: state.hasOtherAuthors,
        searchHighlight: state.search.isNotEmpty ? state.search : null,
        initiallyExpanded: noteInitiallyExpanded(
          note,
          noteCount: state.notes.length,
          threadUnread: _initialThreadUnread,
          readAt: _initialReadAt,
        ),
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

/// Pinned action row inside the thread squircle (multi-panel only).
///
/// In multi-panel mode the unified header carries no thread-specific
/// buttons — they live here, fixed at the top of the squircle so the
/// notes scroll list underneath can fade against its top edge cleanly.
///
/// Start of the row: tag toggles, Todo/Finish, Do later.
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
        CommandWrapper(
          ToggleThreadActive(thread),
          icon: Value(FontAwesomeIcons.circlePlus),
          title: 'To do',
        ),
        tooltipBelow: true,
      );
    } else {
      todoButton = Button.icon(
        CommandWrapper(
          FinishThread(thread),
          icon: Value(FontAwesomeIcons.circle),
          hoverIcon: Value(FontAwesomeIcons.circleCheck),
          title: 'Done',
        ),
        selected: true,
        selectedColor: threadColor,
        tooltipBelow: true,
      );
    }

    final scheduleButton = Button.icon(
      CommandWrapper(
        PickScheduleThread(thread),
        icon: Value(PlotIcon.doLater),
        title: 'Do later',
      ),
      selected: isScheduled,
      selectedColor: threadColor,
      tooltipBelow: true,
    );

    final startGroup = <Widget>[
      todoButton,
      scheduleButton,
      if (!readOnly)
        ThreadAssignee(
          thread: thread,
          showWhenUnassigned: true,
          tooltipBelow: true,
        ),
    ];

    final endGroup = <Widget>[
      PrimaryLinkHeaderActions(thread: thread),
      if (!readOnly) ThreadSharing(thread: thread, tooltipBelow: true),
      Button.icon(_buildThreadMenuCommand(thread), tooltipBelow: true),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colour.sectionHeaderBackground,
        border: Border(
          bottom: BorderSide(color: context.theme.colors.border, width: 1),
        ),
      ),
      // Pinned to the shared [panelHeaderHeight] (rather than padding the
      // buttons' intrinsic height with `xs`) so this band stays exactly as
      // tall as the feed's leading section header in the middle panel —
      // independently derived heights drifted ~1px+ apart on iPad and web.
      // The Row centers its buttons inside the band, which reproduces the
      // old `xs` vertical padding when the tallest child is a ghost icon
      // button.
      child: SizedBox(
        height: panelHeaderHeight(context),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.theme.spacing.lg),
          child: Row(children: [...startGroup, const Spacer(), ...endGroup]),
        ),
      ),
    );
  }

  Command _buildThreadMenuCommand(Thread thread) {
    return ShowCommands(
      title: 'More',
      icon: PlotIcon.menu,
      commandsBuilder: (context) async {
        final priorityBloc = context.read<PriorityBloc?>();
        final groups = await threadCommandGroups(
          thread,
          open: false,
          priorityBloc: priorityBloc,
        );
        return Commands(groups: groups);
      },
    );
  }
}
