import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/util/string.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'logging.dart';

/// Holds data for creating a new Activity with its first Note
class ActivityWithNote {
  ActivityWithNote({required this.activity, required this.noteContent});

  final Activity activity;
  final String noteContent;
}

class ActivityEditor extends StatefulWidget {
  const ActivityEditor({required this.draft, this.expand = false, super.key});

  final Activity draft;
  final bool expand;

  @override
  State<ActivityEditor> createState() => ActivityEditorState();
}

class ActivityEditorState extends State<ActivityEditor> {
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  final GlobalKey<EditableAreaState> _editableAreaKey =
      GlobalKey<EditableAreaState>();
  bool _isEmpty = true;
  String _lastSavedContent = '';
  FocusNode? _currentFocusNode;

  /// Request focus on the editor
  void focus() {
    _editableAreaKey.currentState?.focus();
  }

  @override
  void initState() {
    super.initState();
    _lastSavedContent = widget.draft.preview ?? '';
  }

  @override
  void didUpdateWidget(ActivityEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.draft.preview != oldWidget.draft.preview) {
      _lastSavedContent = widget.draft.preview ?? '';
    }
  }

  @override
  void dispose() {
    _currentFocusNode?.removeListener(_onFocusChange);
    super.dispose();
  }

  @override
  void deactivate() {
    // Save draft when navigating away
    final editorState = _editorKey.currentState;
    if (editorState != null) {
      final content = editorState.serialize();
      _saveDraft(content);
    }
    super.deactivate();
  }

  void _onFocusChange() {
    if (_currentFocusNode != null && !_currentFocusNode!.hasFocus) {
      // Focus lost (blur) - save draft
      final editorState = _editorKey.currentState;
      if (editorState != null) {
        final content = editorState.serialize();
        _saveDraft(content);
      }
    }
  }

  Future<void> _saveDraft(String content) async {
    // Only save if content has changed
    if (content == _lastSavedContent) return;

    final bloc = context.read<PriorityBloc>();
    final updatedDraft = widget.draft.copyWith(
      preview: Value(content.trim().isEmpty ? null : content),
    );
    await bloc.updateDraft(updatedDraft);
    _lastSavedContent = content;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
        return EditableArea(
          key: _editableAreaKey,
          position: EditableAreaPosition.bottom,
          builder: (context, focusNode) {
            // Set up focus listener once
            if (_currentFocusNode != focusNode) {
              _currentFocusNode?.removeListener(_onFocusChange);
              _currentFocusNode = focusNode;
              _currentFocusNode?.addListener(_onFocusChange);
            }

            final editor = Editor(
              key: _editorKey,
              hint: state.draft.type == .note
                  ? 'Add a note'
                  : state.draft.type == .event
                  ? 'Event details'
                  : 'Describe the action',
              autofocus: true,
              focusNode: focusNode,
              twists: state.twists,
              shrinkWrap: !widget.expand,
              initialContent: widget.draft.preview,
              onChange: (value) {
                setState(() {
                  _isEmpty = value.trim().isEmpty;
                });
                // Auto-save on content change (debounced by Editor's onChange)
                _saveDraft(value);
              },
              onSubmitted: (body, {bool alt = false}) async {
                final data = await finalizeDraft(
                  body,
                  twists: state.twists,
                  alt: alt,
                );
                if (!context.mounted) return;

                // Use AddEvent for events, AddActivityWithNote for other types
                if (widget.draft.type == ActivityType.event) {
                  await context.run(
                    AddEvent(data.activity, body.trim().isEmpty ? null : body),
                  );
                } else {
                  await context.run(AddActivityWithNote(data));
                }
              },
            );
            return Column(
              mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                if (widget.expand)
                  Expanded(
                    key: const ValueKey('editor_expanded'),
                    child: editor,
                  )
                else
                  editor,
                // Bottom bar - stays at bottom, above keyboard
                Row(
                  children: [
                    // Left side: Do Now toggle
                    Button.icon(
                      StartAction(
                        widget.draft,
                        onUpdate: (activity) {
                          return context.read<PriorityBloc>().updateDraft(
                            activity,
                          );
                        },
                      ),
                      selected: widget.draft.doNow,
                    ),
                    Button.icon(
                      state.draft.type == .event
                          ? UnscheduleEvent(
                              widget.draft,
                              onUpdate: (activity) {
                                return context.read<PriorityBloc>().updateDraft(
                                  activity,
                                );
                              },
                            )
                          : ScheduleEvent(
                              widget.draft,
                              at: DateTimeRange(
                                DateTime.now(),
                                DateTime.now().add(const Duration(hours: 1)),
                              ),
                              onUpdate: (activity) {
                                return context.read<PriorityBloc>().updateDraft(
                                  activity,
                                );
                              },
                            ),
                      selected: widget.draft.type == .event,
                    ),
                    const Spacer(),
                    // Right side: Save button
                    Button.icon(
                      CommandWrapper(
                        AddActivity(Future.value(widget.draft)),
                        run: (action, context) async {
                          _editorKey.currentState?.submit(false);
                          return const CommandDone();
                        },
                      ),
                      style: ButtonStyle.primary,
                      enabled:
                          !_isEmpty || widget.draft.type == ActivityType.event,
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<ActivityWithNote> finalizeDraft(
    String body, {
    required List<PriorityTwist> twists,
    required bool alt,
  }) async {
    // Generate title from body (first line or first ~50 chars)
    String title;
    if (widget.draft.type == ActivityType.event && body.trim().isEmpty) {
      // For blank events, use priority title with "Focus" suffix
      title = '${widget.draft.priority.title} Focus';
    } else {
      title = body
          .trim()
          .split('\n')
          .first
          .trim()
          .removeMarkdown(replaceLinksWithURL: false);
      if (title.isEmpty) {
        title = 'Untitled';
      }
    }
    log.info('Finalizing draft with title: $title');

    // Apply "Do Now" scheduling only if Cmd-Enter (alt) was used
    final shouldSchedule = alt;
    final hasDateTime = widget.draft.at != null;

    // Create Activity with title and type based on "Do Now" toggle
    final activity = widget.draft.copyWith(
      title: Value(title),
      preview: const Value(null), // No longer using preview field
      draft: false,
      // Set type to action if "Do Now" is toggled OR if Cmd-Enter was used
      type: widget.draft.doNow || shouldSchedule ? ActivityType.action : null,
      on: shouldSchedule && !hasDateTime
          ? Value(CustomDateRange(Date.today(), null))
          : const Value.absent(),
      at: shouldSchedule && hasDateTime
          ? Value(
              DateTimeRange(
                DateTime.now(),
                DateTime.now().add(Duration(hours: 1)),
              ),
            )
          : const Value.absent(),
    );

    return ActivityWithNote(activity: activity, noteContent: body);
  }
}
