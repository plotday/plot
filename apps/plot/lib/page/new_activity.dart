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
  });

  final String? startTime;
  final String? endTime;
  final int? duration; // Duration in minutes
  final String? priorityId;

  @override
  State<NewActivityPage> createState() => NewActivityPageState();
}

class NewActivityPageState extends State<NewActivityPage> {
  final GlobalKey<ActivityEditorState> _activityEditorKey =
      GlobalKey<ActivityEditorState>();

  // Save reference to provider to avoid looking it up in dispose()
  PriorityShortcutsProviderState? _provider;
  bool _hasAppliedQueryParams = false;

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

    // Apply to draft if any query parameters were provided
    if (queryStartTime != null || queryPriority != null) {
      Activity updatedDraft;
      if (queryStartTime != null && queryEndTime != null) {
        updatedDraft = currentDraft.copyWith(
          at: Value(DateTimeRange(queryStartTime, queryEndTime)),
          priority: queryPriority ?? currentDraft.priority,
          type: .event,
          draft: true,
        );
      } else if (queryPriority != null) {
        updatedDraft = currentDraft.copyWith(
          priority: queryPriority,
          draft: true,
        );
      } else {
        return; // No changes to apply
      }
      await bloc.updateDraft(updatedDraft);
    }
  }

  @override
  void dispose() {
    // Unregister from the focus coordination provider using saved reference
    _provider?.unregisterActivityPanel();
    super.dispose();
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
                if (!didPop && !layoutState.multiPanel) {
                  context.run(ChangeCurrentActivity(null));
                }
              },
              child: Scaffold(
                translucent: true,
                scrollable: false,
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
