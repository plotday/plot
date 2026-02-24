import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart' hide Link;
import 'package:plot/state/priority.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/state/layout.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:plot/command/command.dart';
import 'package:plot/widget/activity_header_notifier.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;

@RoutePage(name: "ActivityRoute")
class ActivityPage implements AutoRouteWrapper {
  ActivityPage({@PathParam("activityId") required String activityIdString})
    : activityId = ActivityId.fromShortString(activityIdString);

  final ActivityId activityId;

  @override
  Widget wrappedRoute(BuildContext context) {
    return ActivityBlocProvider(
      activityId: activityId,
      activity: null, // Let the bloc load the activity
      child: BlocConsumer<ActivityBloc, ActivityState>(
        listener: (context, state) {
          context.read<PriorityBloc>().setActivity(state.activity);
        },
        listenWhen: (previous, current) =>
            previous.activity.id != current.activity.id,
        builder: (context, state) {
          return _ActivityPageContent();
        },
      ),
    );
  }
}

class _ActivityPageContent extends StatefulWidget {
  const _ActivityPageContent();

  @override
  State<_ActivityPageContent> createState() => _ActivityPageContentState();
}

class _ActivityPageContentState extends State<_ActivityPageContent> {
  final GlobalKey<NoteEditorState> _noteEditorKey =
      GlobalKey<NoteEditorState>();

  // Store reference to provider to avoid unsafe ancestor lookup in dispose()
  PriorityShortcutsProviderState? _provider;

  // Store reference to activity header notifier
  ActivityHeaderNotifier? _headerNotifier;

  // Timer for delayed read marking
  Timer? _markReadTimer;

  // Flag to ensure setActivity is only called once on initial load
  bool _hasSetInitialActivity = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Save reference during a safe lifecycle method
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    _headerNotifier = ActivityHeaderNotifierProvider.read(context);
    // Schedule marking activity as read after 750ms
    _scheduleMarkAsRead();

    // Ensure PriorityBloc knows about this activity on first load
    if (!_hasSetInitialActivity) {
      _hasSetInitialActivity = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final activity = context.read<ActivityBloc>().state.activity;
          context.read<PriorityBloc>().setActivity(activity);
        }
      });
    }

    // Register with ActivityHeaderNotifier for unified header search
    // Deferred to avoid notifyListeners() during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _registerWithHeaderNotifier();
    });
  }

  void _registerWithHeaderNotifier() {
    final state = context.read<ActivityBloc>().state;
    _headerNotifier?.register(
      onSearchChanged: (search) =>
          context.read<ActivityBloc>().updateSearch(search),
      onSearchClosed: () {
        context.read<ActivityBloc>().updateFilter([]);
        context.read<ActivityBloc>().setThreadFilter(null);
      },
      tags: state.tags,
      filter: state.filter,
    );
  }

  @override
  void dispose() {
    // Cancel the mark-as-read timer if still pending
    _markReadTimer?.cancel();
    // Unregister from the focus coordination provider
    // Use saved reference instead of looking up during dispose()
    _provider?.unregisterActivityPanel();
    // Unregister from activity header notifier
    _headerNotifier?.unregister();
    super.dispose();
  }

  /// Schedules marking the activity as read after 750ms.
  /// Cancels any previously scheduled mark-as-read operation.
  void _scheduleMarkAsRead() {
    // Cancel any existing timer
    _markReadTimer?.cancel();

    // Start new timer for 750ms delay
    _markReadTimer = Timer(const Duration(milliseconds: 750), () {
      final activity = context.read<ActivityBloc>().state.activity;
      if (activity.unread) {
        activity.copyWith(unread: false).save();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ActivityBloc, ActivityState>(
      listener: (context, state) {
        // Update header notifier when tags/filter change
        _headerNotifier?.updateTags(state.tags, state.filter);
      },
      listenWhen: (previous, current) =>
          previous.tags != current.tags || previous.filter != current.filter,
      child: BlocListener<ActivityBloc, ActivityState>(
        listener: (context, state) {
          // Reschedule mark as read when new notes are synced
          _scheduleMarkAsRead();
        },
        listenWhen: (previous, current) =>
            previous.notes != current.notes && current.activity.unread,
        child: BlocListener<ActivityBloc, ActivityState>(
        listener: (context, state) {
          // Focus NoteEditor when activity thread changes
          // (BidirectionalListSelector is keyed by activity.id, so it creates a fresh controller)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _noteEditorKey.currentState?.focus();
          });
        },
        listenWhen: (previous, current) =>
            previous.activity.id != current.activity.id,
        child: BlocBuilder<ActivityBloc, ActivityState>(
          builder: (context, state) {
            return _buildContent(context, state);
          },
        ),
      ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ActivityState state) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutStateForPanels) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              if (ModalProvider.tryDismissTopModal(context)) return;
              if (!layoutStateForPanels.multiPanel) {
                context.run(ChangeCurrentActivity(null));
              }
            }
          },
          child: BidirectionalListSelector(
            key: ValueKey('activity_list_${state.activity.id}'),
            reverse: true,
            builder: (context, listController) {
              // Register this ActivityPage with the global focus coordination provider
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
                          final activityBloc = context.read<ActivityBloc>();
                          context.run(
                            OpenFocusedItemActions(listController, (index) {
                              final note = _getNoteAtIndex(state, index);
                              if (note == null) return [];
                              return noteCommandGroups(
                                note,
                                activityBloc: activityBloc,
                              );
                            }),
                          );
                          return KeyEventResult.handled;
                        }
                      }
                    }
                    if (event.logicalKey == LogicalKeyboardKey.escape) {
                      // Cancel editing if active
                      final activityBloc = context.read<ActivityBloc>();
                      if (activityBloc.state.editingNote != null) {
                        activityBloc.setEditingNote(null);
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
                      title: 'Topic: ${state.activity.displayTitle}',
                      commands: activityCommands(state.activity),
                    ),
                  ],
                  child: Scaffold(
                    scrollable: false,
                    translucent: true,
                    childPad: false,
                    body: Column(
                      spacing: 8,
                      children: [
                        _ActivitySecondaryBar(
                          activity: state.activity,
                          tags: state.tags,
                          threadNoteId: state.threadNoteId,
                        ),
                        Flexible(
                          flex: 1,
                          fit: FlexFit.tight,
                          child: _buildActivityList(
                            state,
                            listController,
                            context,
                          ),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: Padding(
                            padding: .only(
                              left: layoutStateForPanels.multiPanel ? 12 : 0,
                              right: layoutStateForPanels.multiPanel ? 12 : 0,
                              bottom: layoutStateForPanels.multiPanel ? 12 : 0,
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

  int _getTotalItemCount(ActivityState state) {
    return state.notes.length;
  }

  Note? _getNoteAtIndex(ActivityState state, int index) {
    if (index >= 0 && index < state.notes.length) {
      return state.notes[index];
    }
    return null;
  }

  Widget _buildActivityList(
    ActivityState state,
    BidirectionalListController listController,
    BuildContext context,
  ) {
    final totalItems = _getTotalItemCount(state);

    return BidirectionalList(
      controller: listController,
      scrollController: ScrollControllerContext.of(context),
      first: 0,
      count: totalItems,
      reverse: true,
      doneStart: true,
      doneEnd: true,
      fetcher: (first, count) =>
          Future<void>.value(), // No pagination needed for ActivityPage
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
    ActivityState state,
    int index,
    FocusNode focusNode, {
    int? reorderableIndex,
  }) {
    final note = _getNoteAtIndex(state, index);
    if (note != null) {
      return NoteWidget(
        note: note,
        selected: false, // No selection on ActivityPage
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

/// Secondary actions bar for ActivityPage. Combines:
/// - Primary command button (Complete/Start/etc.)
/// - Active tag toggles (up to 3)
/// - Thread filter badge
/// - Activity links
class _ActivitySecondaryBar extends StatelessWidget {
  const _ActivitySecondaryBar({
    required this.activity,
    required this.tags,
    this.threadNoteId,
  });

  final Activity activity;
  final List<(Tag, int)> tags;
  final NoteId? threadNoteId;

  @override
  Widget build(BuildContext context) {
    final hasLinks = activity.links != null && activity.links!.isNotEmpty;
    final hasThread = threadNoteId != null;
    final activeTags = tags
        .where((tagData) => activity.hasTag(tagData.$1))
        .take(3)
        .toList();

    // Don't show the bar if there's nothing to display
    if (!hasLinks && !hasThread && activeTags.isEmpty) {
      return const SizedBox.shrink();
    }

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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                // Primary command
                Button.icon(
                  primaryActivityCommand(activity, stateIcon: false),
                ),

                // Active tag toggles
                ...activeTags.map(
                  (tagData) => Button.icon(
                    ToggleActivityTag(activity, tagData.$1),
                  ),
                ),

                // Thread filter badge
                if (hasThread) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => context
                        .read<ActivityBloc>()
                        .setThreadFilter(null),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
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
                              style: context.theme.typography.xs
                                  .copyWith(color: context.colour.accent),
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

                // Spacer before links
                if (hasLinks) ...[
                  const Spacer(),
                  ..._buildLinks(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLinks(BuildContext context) {
    final links = activity.links!;
    final borderRadius = BorderRadius.circular(8);
    final ghostStyle = FButtonStyle.ghost(
      (style) => style.copyWith(
        // ignore: unused_result
        decoration: FWidgetStateMap({
          WidgetState.hovered | WidgetState.pressed: BoxDecoration(
            borderRadius: borderRadius,
            color: context.theme.colors.secondary,
          ),
          WidgetState.any: BoxDecoration(
            borderRadius: borderRadius,
          ),
        }),
        // ignore: unused_result
        contentStyle: style.contentStyle.copyWith(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
      ),
    );
    final textStyle = TextStyle(
      fontSize: context.theme.typography.sm.fontSize,
    );

    final children = <Widget>[];
    for (var i = 0; i < links.length; i++) {
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '\u00B7',
              style: textStyle.copyWith(
                color: context.theme.colors.border,
              ),
            ),
          ),
        );
      }
      children.add(NoteLinkWidget(
        link: links[i],
        style: ghostStyle,
        textStyle: textStyle,
      ));
    }
    return children;
  }
}
