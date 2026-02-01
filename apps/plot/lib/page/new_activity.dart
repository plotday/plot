import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:auto_route/auto_route.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/widget/activity_editor.dart';
import 'package:plot/widget/scheduler.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/layout.dart';
import 'package:plot/command/command.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/page/priority.dart'
    show ActivityPanelControllerProvider, PriorityShortcutsProviderState;
import 'package:plot/store/store.dart';
import 'logging.dart';

@RoutePage(name: "NewActivityWrapperRoute")
class NewActivityWrapper implements AutoRouteWrapper {
  const NewActivityWrapper();

  @override
  Widget wrappedRoute(BuildContext context) {
    return AutoRouter(placeholder: (context) => const LoadingPage());
  }
}

@RoutePage()
class NewActivityPage extends StatefulWidget {
  const NewActivityPage({
    super.key,
    @QueryParam('startTime') this.startTime,
    @QueryParam('endTime') this.endTime,
    @QueryParam('duration') this.duration,
    @QueryParam('priorityId') this.priorityId,
    @QueryParam('activityType') this.activityType,
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;
  final String? activityType;

  @override
  State<NewActivityPage> createState() => NewActivityPageState();
}

class NewActivityPageState extends State<NewActivityPage> {
  final GlobalKey<ActivityEditorState> _activityEditorKey =
      GlobalKey<ActivityEditorState>();

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;
  bool _hasAppliedQueryParams = false;

  // Twists for the selected draft priority (may differ from context priority)
  List<PriorityTwist>? _draftTwists;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Save the provider reference
    _provider = ActivityPanelControllerProvider.maybeOf(context);
    // Register ActivityEditor with the focus coordination provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider?.registerActivityPanel(
        editorFocusCallback: () => _activityEditorKey.currentState?.focus(),
      );
    });

    // Apply query parameters to draft if present
    if (!_hasAppliedQueryParams) {
      _hasAppliedQueryParams = true;
      _applyQueryParametersToDraft();
    }
  }

  Future<void> _applyQueryParametersToDraft() async {
    final bloc = context.read<PriorityBloc>();
    final currentDraft = bloc.state.draft;

    // Parse query parameters
    DateTime? queryStartTime;
    DateTime? queryEndTime;
    Priority? queryPriority;
    ActivityType? queryActivityType;

    if (widget.startTime != null) {
      try {
        queryStartTime = DateTime.parse(widget.startTime!);
      } catch (e) {
        log.warning('[NewActivityPage] Failed to parse startTime', e);
      }
    }

    if (widget.endTime != null) {
      try {
        queryEndTime = DateTime.parse(widget.endTime!);
      } catch (e) {
        log.warning('[NewActivityPage] Failed to parse endTime', e);
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
        log.warning('[NewActivityPage] Failed to parse priorityId', e);
      }
    }

    // Parse activityType if provided
    if (widget.activityType != null) {
      try {
        // Convert string to ActivityType enum
        if (widget.activityType == 'action') {
          queryActivityType = ActivityType.action;
        } else if (widget.activityType == 'event') {
          queryActivityType = ActivityType.event;
        } else if (widget.activityType == 'note') {
          queryActivityType = ActivityType.note;
        }
      } catch (e) {
        log.warning('[NewActivityPage] Failed to parse activityType', e);
      }
    }

    // Apply to draft if any query parameters were provided
    if (queryStartTime != null ||
        queryPriority != null ||
        queryActivityType != null) {
      Activity updatedDraft;
      if (queryStartTime != null && queryEndTime != null) {
        // StartTime takes precedence - create an event
        updatedDraft = currentDraft.copyWith(
          at: Value(DateTimeRange(queryStartTime, queryEndTime)),
          priority: queryPriority ?? currentDraft.priority,
          type: .event,
          draft: true,
        );
        await bloc.updateDraft(updatedDraft);
      } else if (queryActivityType != null) {
        // Apply activity type if no startTime
        if (queryActivityType == ActivityType.action) {
          // Set activity type to action and start it in "Do Now" state
          // This replicates what StartAction does
          final hasDateTime = currentDraft.at != null;
          updatedDraft = currentDraft.copyWith(
            type: ActivityType.action,
            priority: queryPriority ?? currentDraft.priority,
            // Apply "Do Now" scheduling
            at: hasDateTime
                ? Value(
                    DateTimeRange(
                      Time.now(),
                      Time.now().add(Duration(hours: 1)),
                    ),
                  )
                : const Value.absent(),
            on: !hasDateTime
                ? Value(CustomDateRange(Date.today(), null))
                : const Value.absent(),
            order: Order.first(),
            draft: true,
          );
          await bloc.updateDraft(updatedDraft);
        } else {
          updatedDraft = currentDraft.copyWith(
            type: queryActivityType,
            priority: queryPriority ?? currentDraft.priority,
            draft: true,
          );
          await bloc.updateDraft(updatedDraft);
        }
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
      }
    }
  }

  @override
  void dispose() {
    // Unregister from the focus coordination provider using saved reference
    _provider?.unregisterActivityPanel();
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
  }

  Future<void> _selectPriority(
    BuildContext context,
    PriorityState state,
  ) async {
    final bloc = context.read<PriorityBloc>();
    final result = await SelectModal.open<Priority>(
      context,
      items: (search) async {
        final priorities = await Priority.get(
          order: PriorityOrder.nested,
          search: search,
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
        '[NewActivityPage._selectPriority] Updating draft priority from ${state.draft.priority.id} (${state.draft.priority.title}) to ${result.value.id} (${result.value.title})',
      );
      // Update just the draft's priority without changing the global priority context
      final updatedDraft = state.draft.copyWith(priority: result.value);
      await bloc.updateDraft(updatedDraft);

      // Load twists for the newly selected priority
      await _loadTwistsForPriority(result.value);

      log.info(
        '[NewActivityPage._selectPriority] Draft priority update complete',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LayoutBloc, LayoutState>(
      builder: (context, layoutState) {
        return BlocBuilder<PriorityBloc, PriorityState>(
          builder: (context, state) {
            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop) {
                  if (ModalProvider.tryDismissTopModal(context)) return;
                  if (!layoutState.multiPanel) {
                    context.run(ChangeCurrentActivity(null));
                  }
                }
              },
              child: Scaffold(
                translucent: true,
                scrollable: false,
                childPad: layoutState.multiPanel,
                header:
                    layoutState.middlePanelVisible || !layoutState.multiPanel
                    ? null
                    : Header(
                        title: 'New Activity',
                        prefixCommands: [
                          CommandWrapper(
                            ChangeCurrentActivity(null),
                            icon: Value(PlotIcon.back),
                          ),
                        ],
                      ),
                body: LayoutBuilder(
                  builder: (context, constraints) {
                    // Single panel mode: editor at bottom, edge-to-edge
                    if (!layoutState.multiPanel) {
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          // Flexible space at top (takes remaining space)
                          Spacer(),

                          // PriorityLabel and Scheduler with horizontal padding
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Column(
                              children: [
                                // PriorityLabel (centered, clickable, directly above editor)
                                Center(
                                  child: Tapable(
                                    onTap: () =>
                                        _selectPriority(context, state),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: context.theme.colors.border,
                                          width: 1,
                                        ),
                                        borderRadius: BorderRadius.circular(24),
                                      ),
                                      child: PriorityLabel(
                                        priority: state.draft.priority,
                                        muted: true,
                                      ),
                                    ),
                                  ),
                                ),

                                SizedBox(height: 16),

                                // Scheduler (if event, between PriorityLabel and editor)
                                if (state.draft.type == .event &&
                                    state.draft.at != null) ...[
                                  Center(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: 340,
                                      ),
                                      child: Scheduler(
                                        value: state.draft.at!,
                                        onChanged: (newAt) async {
                                          final updatedDraft = state.draft
                                              .copyWith(at: Value(newAt));
                                          await context
                                              .read<PriorityBloc>()
                                              .updateDraft(updatedDraft);
                                        },
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: 16),
                                ],
                              ],
                            ),
                          ),

                          // ActivityEditor (at bottom, edge-to-edge)
                          ActivityEditor(
                            key: _activityEditorKey,
                            draft: state.draft,
                            draftNote: state.draftNote,
                            twists: _draftTwists ?? state.twists,
                            onDraftChanged: (activity, {note}) async {
                              await context.read<PriorityBloc>().updateDraft(
                                activity,
                                note: note,
                              );
                            },
                            flushToBottom: true,
                          ),
                        ],
                      );
                    }

                    // Multi-panel mode: keep existing centered layout
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        // Fixed 25% spacing from top
                        SizedBox(height: constraints.maxHeight * 0.25),

                        // PriorityLabel (centered, clickable)
                        Center(
                          child: Tapable(
                            onTap: () => _selectPriority(context, state),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: context.theme.colors.border,
                                  width: 1,
                                ),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: PriorityLabel(
                                priority: state.draft.priority,
                                muted: true,
                              ),
                            ),
                          ),
                        ),

                        SizedBox(height: 16),

                        // ActivityEditor (height constrained to ~50% viewport)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * 0.5,
                          ),
                          child: ActivityEditor(
                            key: _activityEditorKey,
                            draft: state.draft,
                            draftNote: state.draftNote,
                            twists: _draftTwists ?? state.twists,
                            onDraftChanged: (activity, {note}) async {
                              await context.read<PriorityBloc>().updateDraft(
                                activity,
                                note: note,
                              );
                            },
                            flushToBottom: false,
                          ),
                        ),

                        SizedBox(height: 16),

                        if (state.draft.type == .event &&
                            state.draft.at != null)
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: 340),
                            child: Scheduler(
                              value: state.draft.at!,
                              onChanged: (newAt) async {
                                final updatedDraft = state.draft.copyWith(
                                  at: Value(newAt),
                                );
                                await context.read<PriorityBloc>().updateDraft(
                                  updatedDraft,
                                );
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}
