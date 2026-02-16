import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'logging.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    required this.draft,
    this.flushToBottom = false,
    super.key,
  });

  final Note draft;
  final bool flushToBottom;

  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> {
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  final GlobalKey<EditableAreaState> _editableAreaKey =
      GlobalKey<EditableAreaState>();
  bool _isEmpty = true;
  bool _finalized = false;
  bool _saving = false;
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
    _lastSavedContent = widget.draft.content ?? '';
    _lastDraftNoteId = widget.draft.id;
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newDraftNoteId = widget.draft.id;
    final newContent = widget.draft.content ?? '';

    // Reset editor if draft note ID changed
    if (newDraftNoteId != _lastDraftNoteId) {
      _editorKey.currentState?.reset(newContent);
      _lastDraftNoteId = newDraftNoteId;
      _lastSavedContent = newContent;
    } else if (newContent != _lastSavedContent) {
      // Update last saved content if it changed but ID didn't
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
    if (!_finalized) {
      final editorState = _editorKey.currentState;
      if (editorState != null) {
        final content = editorState.serialize();
        _saveDraftNote(content);
      }
    }
    super.deactivate();
  }

  void _onFocusChange() {
    if (_finalized) return;
    if (_currentFocusNode != null && !_currentFocusNode!.hasFocus) {
      // Focus lost (blur) - save draft
      final editorState = _editorKey.currentState;
      if (editorState != null) {
        final content = editorState.serialize();
        _saveDraftNote(content);
      }
    }
  }

  Future<void> _saveDraftNote(String content) async {
    if (_finalized) return;
    // Only save if content has changed
    if (content == _lastSavedContent) return;

    final activityBloc = context.read<ActivityBloc>();
    log.info('Saving draft note with content: $content');
    final updatedDraft = widget.draft.copyWith(content: content);
    await activityBloc.updateDraft(updatedDraft);
    _lastSavedContent = content;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PriorityBloc, PriorityState>(
      builder: (context, state) {
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

            final editor = Editor(
              key: _editorKey,
              hint: 'Add a note',
              autofocus: true,
              focusNode: focusNode,
              twists: state.twists,
              actors: state.actors,
              shrinkWrap: true,
              initialContent: widget.draft.content,
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
              onSubmitted: (body, {bool alt = false}) async {
                final note = finalizeDraft(body, alt: alt);
                if (!context.mounted) return;
                setState(() {
                  _saving = true;
                });
                try {
                  await context.run(AddNote(note));
                } finally {
                  if (mounted) {
                    setState(() {
                      _saving = false;
                    });
                  }
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
                  // Reply indicator
                  BlocBuilder<ActivityBloc, ActivityState>(
                    buildWhen: (prev, curr) => prev.replyTo != curr.replyTo,
                    builder: (context, activityState) {
                      final replyTo = activityState.replyTo;
                      if (replyTo == null) return const SizedBox.shrink();
                      final raw = replyTo.content ?? '';
                      final firstLine = raw.split('\n').first;
                      final preview = firstLine.length > 60
                          ? '${firstLine.substring(0, 60)}...'
                          : firstLine;
                      return Padding(
                        padding: const EdgeInsets.only(
                          left: 6,
                          right: 6,
                          top: 4,
                        ),
                        child: Container(
                          padding: const EdgeInsets.only(
                            left: 8,
                            top: 4,
                            bottom: 4,
                          ),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: context.colour.muted,
                                width: 2,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  preview,
                                  style: context.theme.typography.xs.copyWith(
                                    color: context.colour.muted,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              GestureDetector(
                                onTap: () {
                                  context.read<ActivityBloc>().setReplyTo(null);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Icon(
                                    FontAwesomeIcons.xmark,
                                    size: 12,
                                    color: context.colour.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  Flexible(
                    child: IgnorePointer(
                      ignoring: _saving,
                      child: Opacity(
                        opacity: _saving ? 0.6 : 1.0,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
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
                                  _editorKey.currentState?.insertTextAtCursor(
                                    text,
                                  );
                                },
                                onError: (error) {
                                  Alert.show(context, error);
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Bottom bar - stays at bottom, above keyboard
                  Row(
                    children: [
                      IgnorePointer(
                        ignoring: _saving,
                        child: Opacity(
                          opacity: _saving ? 0.6 : 1.0,
                          child: Row(
                            children: [
                              // Left side: Do Now toggle
                              Button.icon(
                                ToggleNoteTag(
                                  widget.draft,
                                  Tag.now,
                                  Base.actorId,
                                ),
                                selected: widget.draft.isAssignedTo(
                                  Base.actorId,
                                ),
                              ),
                              // Private toggle
                              if (!widget.draft.private ||
                                  widget.draft.authorId == Base.actorId)
                                Button.icon(
                                  ToggleNoteTag(
                                    widget.draft,
                                    Tag.private,
                                    Base.actorId,
                                  ),
                                  selected: widget.draft.private,
                                ),
                              Button.icon(
                                AttachFile(
                                  priorityId: context
                                      .read<ActivityBloc>()
                                      .state
                                      .activity
                                      .priority
                                      .id
                                      .toString(),
                                  currentLinks: widget.draft.links ?? const [],
                                  onLinksChanged: (links) {
                                    final updatedDraft = widget.draft.copyWith(
                                      links: links,
                                    );
                                    context.read<ActivityBloc>().updateDraft(
                                      updatedDraft,
                                    );
                                  },
                                ),
                                selected:
                                    widget.draft.links?.any(
                                      (l) => l.type == LinkType.file,
                                    ) ??
                                    false,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Right side: Save button (always visible)
                      Button.icon(
                        CommandWrapper(
                          AddNote(Future.value(widget.draft)),
                          run: (action, context) async {
                            _editorKey.currentState?.submit(false);
                            return const CommandDone();
                          },
                        ),
                        style: ButtonStyle.primary,
                        loading: _saving,
                        enabled:
                            !_saving &&
                            (!_isEmpty ||
                                (widget.draft.links?.any(
                                      (l) => l.type == LinkType.file,
                                    ) ??
                                    false)),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<Note> finalizeDraft(String body, {bool alt = false}) async {
    _finalized = true;

    // Get replyTo from ActivityBloc state
    final activityBloc = context.read<ActivityBloc>();
    final replyTo = activityBloc.state.replyTo;

    Note note = widget.draft.copyWith(
      content: body.isEmpty ? null : body,
      draft: false,
      reNoteId: replyTo?.id,
    );

    // If Cmd-Enter was pressed, assign the note to current user
    if (alt && !note.isAssignedTo(Base.actorId)) {
      note = note.assignTo(Base.actorId);
    }

    return note;
  }
}
