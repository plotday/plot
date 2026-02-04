import 'package:plot/store/store.dart';
import 'package:plot/util/string.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'logging.dart';

/// Holds data for creating a new Activity with its first Note
class ActivityWithNote {
  ActivityWithNote({required this.activity, this.note});

  final Activity activity;
  final Note? note;
}

class ActivityEditor extends StatefulWidget {
  const ActivityEditor({
    required this.draft,
    required this.draftNote,
    required this.twists,
    this.actors = const [],
    required this.onDraftChanged,
    this.flushToBottom = false,
    super.key,
  });

  final Activity draft;
  final Note draftNote;
  final List<PriorityTwist> twists;
  final List<Actor> actors;
  final Future<void> Function(Activity activity, {Note? note}) onDraftChanged;
  final bool flushToBottom;

  @override
  State<ActivityEditor> createState() => ActivityEditorState();
}

class ActivityEditorState extends State<ActivityEditor> {
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  final GlobalKey<EditableAreaState> _editableAreaKey =
      GlobalKey<EditableAreaState>();
  bool _isEmpty = true;
  bool _finalized = false;
  String _lastSavedContent = '';
  Uuid? _lastDraftNoteId;
  FocusNode? _currentFocusNode;

  /// Request focus on the editor
  void focus() {
    _editableAreaKey.currentState?.focus();
  }

  @override
  void initState() {
    super.initState();
    // Get initial content from draft note instead of preview
    _lastSavedContent = widget.draftNote.content ?? '';
    _lastDraftNoteId = widget.draftNote.id;
    log.info(
      '[ActivityEditor.initState] Initialized with draft ${widget.draft.id}, priority=${widget.draft.priority.id} (${widget.draft.priority.title}), content length=${_lastSavedContent.length}, draftNote=${widget.draftNote.id}',
    );
  }

  @override
  void didUpdateWidget(ActivityEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newDraftNoteId = widget.draftNote.id;
    final newContent = widget.draftNote.content ?? '';

    // Reset editor if draft note ID changed
    if (newDraftNoteId != _lastDraftNoteId) {
      log.info(
        '[ActivityEditor.didUpdateWidget] Draft note ID changed from $_lastDraftNoteId to $newDraftNoteId',
      );
      if (_lastDraftNoteId != null && newDraftNoteId == null) {
        log.info(
          '[ActivityEditor.didUpdateWidget] Resetting editor with content length=${newContent.length}, draft=${widget.draft.id}, priority=${widget.draft.priority.id} (${widget.draft.priority.title})',
        );
        // Defer reset until after current frame to avoid modifying overlay during layout
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _editorKey.currentState?.reset(newContent);
          }
        });
      }
      _lastDraftNoteId = newDraftNoteId;
      _lastSavedContent = newContent;
    } else if (newContent != _lastSavedContent) {
      // Update last saved content if it changed but ID didn't
      log.info(
        '[ActivityEditor.didUpdateWidget] Content changed from length ${_lastSavedContent.length} to ${newContent.length}, draft=${widget.draft.id}, priority=${widget.draft.priority.id} (${widget.draft.priority.title})',
      );
      _lastSavedContent = newContent;
    }
  }

  @override
  void dispose() {
    _currentFocusNode?.removeListener(_onFocusChange);
    super.dispose();
  }

  @override
  void deactivate() {
    // Save draft when navigating away (unless finalized)
    log.info(
      '[ActivityEditor.deactivate] Deactivating editor, draft=${widget.draft.id}, priority=${widget.draft.priority.id} (${widget.draft.priority.title}), finalized=$_finalized',
    );
    if (!_finalized) {
      final editorState = _editorKey.currentState;
      if (editorState != null) {
        final content = editorState.serialize();
        log.info(
          '[ActivityEditor.deactivate] Saving content with length ${content.length}',
        );
        _saveDraft(content);
      }
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

    log.info(
      '[ActivityEditor._saveDraft] Saving draft: content length=${content.length}, draft=${widget.draft.id}, priority=${widget.draft.priority.id} (${widget.draft.priority.title})',
    );

    // Get or create draft note
    final existingNote = widget.draftNote.activityId == widget.draft.id
        ? widget.draftNote
        : null;

    final Note note;
    if (existingNote != null) {
      // Update existing note
      note = existingNote.copyWith(content: content);
    } else {
      // Create new draft note
      note = Note.draft(activityId: widget.draft.id);
    }

    await widget.onDraftChanged(widget.draft, note: note);
    _lastSavedContent = content;
  }

  @override
  Widget build(BuildContext context) {
    return EditableArea(
      key: _editableAreaKey,
      padding: false,
      position: EditableAreaPosition.bottom,
      flushToBottom: widget.flushToBottom,
      builder: (context, focusNode) {
        // Set up focus listener once
        if (_currentFocusNode != focusNode) {
          _currentFocusNode?.removeListener(_onFocusChange);
          _currentFocusNode = focusNode;
          _currentFocusNode?.addListener(_onFocusChange);
        }

        final initialContent = widget.draftNote.content;
        log.info(
          '[ActivityEditor.build] Building Editor with initialContent length=${initialContent?.length ?? 0}, draft=${widget.draft.id}, priority=${widget.draft.priority.id} (${widget.draft.priority.title}), draftNote=${widget.draftNote.id}',
        );

        final editor = Editor(
          key: _editorKey,
          hint: widget.draft.type == .note
              ? 'Start a new topic'
              : widget.draft.type == .event
              ? 'Event details'
              : 'Add an action',
          autofocus: true,
          focusNode: focusNode,
          twists: widget.twists,
          actors: widget.actors,
          shrinkWrap: true,
          initialContent: initialContent,
          onIsEmptyChanged: (isEmpty) {
            // Defer setState to avoid calling it during build
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _isEmpty = isEmpty;
                });
              }
            });
          },
          onChange: (value) {
            // Auto-save on content change (debounced by Editor's onChange)
            _saveDraft(value);
          },
          onSubmitted: (body, {bool alt = false}) async {
            final data = await finalizeDraft(
              body,
              twists: widget.twists,
              alt: alt,
            );
            if (!context.mounted) return;

            // Use AddEvent for events, AddActivityWithNote for other types
            if (widget.draft.type == ActivityType.event) {
              await context.run(AddEvent(data.activity, data.note));
            } else {
              await context.run(AddActivityWithNote(data));
            }
          },
        );
        return Padding(
          padding: const EdgeInsets.only(
            left: 12,
            right: 12,
            top: 4,
            bottom: 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 4,
            children: [
              Flexible(
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          top: 8,
                          bottom: 4,
                          left: 6,
                          right: 6,
                        ),
                        child: editor,
                      ),
                    ),
                    if (_isEmpty)
                      SpeechDictationButton(
                        onResult: (text) {
                          _editorKey.currentState?.insertTextAtCursor(text);
                        },
                        onError: (error) {
                          Alert.show(context, error);
                        },
                      ),
                  ],
                ),
              ),
              // Bottom bar - stays at bottom, above keyboard
              Row(
                children: [
                  // Left side: Do Now toggle
                  Button.icon(
                    ToggleAction(
                      widget.draft,
                      onUpdate: (activity) => widget.onDraftChanged(activity),
                    ),
                    selected: widget.draft.doNow,
                  ),
                  Button.icon(
                    widget.draft.type == .event
                        ? UnscheduleEvent(
                            widget.draft,
                            onUpdate: (activity) =>
                                widget.onDraftChanged(activity),
                          )
                        : ScheduleEvent(
                            widget.draft,
                            at: DateTimeRange(
                              Time.now(),
                              Time.now().add(const Duration(hours: 1)),
                            ),
                            onUpdate: (activity) =>
                                widget.onDraftChanged(activity),
                          ),
                    selected: widget.draft.type == .event,
                  ),
                  if (!widget.draft.private || widget.draft.authorId == Base.actorId)
                    Button.icon(
                      ToggleActivityPrivate(
                        widget.draft,
                        onUpdate: (activity) =>
                            widget.onDraftChanged(activity),
                      ),
                      selected: widget.draft.private,
                    ),
                  const Spacer(),
                  // Right side: Save button (always visible)
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
          ),
        );
      },
    );
  }

  Future<ActivityWithNote> finalizeDraft(
    String body, {
    required List<PriorityTwist> twists,
    required bool alt,
  }) async {
    _finalized = true;

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
          ? Value(DateTimeRange(Time.now(), Time.now().add(Duration(hours: 1))))
          : const Value.absent(),
    );

    // Create note from draft note or create new one if content is provided
    Note? note;
    if (body.trim().isNotEmpty) {
      // Use existing draft note and update its content
      note = widget.draftNote.copyWith(content: body);
    }

    return ActivityWithNote(activity: activity, note: note);
  }
}
