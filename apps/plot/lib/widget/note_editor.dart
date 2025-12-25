import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'logging.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    required this.draft,
    this.expand = false,
    this.flushToBottom = false,
    super.key,
  });

  final Note draft;
  final bool expand;
  final bool flushToBottom;

  @override
  State<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends State<NoteEditor> {
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  final GlobalKey<EditableAreaState> _editableAreaKey =
      GlobalKey<EditableAreaState>();
  bool _isEmpty = true;
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
    // Save draft when navigating away
    final editorState = _editorKey.currentState;
    if (editorState != null) {
      final content = editorState.serialize();
      _saveDraftNote(content);
    }
    super.deactivate();
  }

  void _onFocusChange() {
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
              shrinkWrap: !widget.expand,
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
                await context.run(AddNote(finalizeDraft(body)));
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
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: editor),
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
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: editor),
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
                // Bottom bar - stays at bottom, above keyboard
                Row(
                  children: [
                    // Left side: Do Now toggle
                    Button.icon(
                      CommandWrapper(
                        ToggleNoteTag(
                          widget.draft,
                          Tag.now,
                          Base.actorId,
                        ),
                        run: (action, context) async {
                          // Get ActivityBloc before async gap
                          final activityBloc = context.read<ActivityBloc>();
                          final result = await action.run(context);
                          // Update draft to trigger UI rebuild
                          final updatedDraft = widget.draft.copyWith();
                          await activityBloc.updateDraft(updatedDraft);
                          return result;
                        },
                      ),
                      selected: widget.draft.isAssignedTo(Base.actorId),
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
                      enabled: !_isEmpty,
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

  Future<Note> finalizeDraft(String body) async {
    return widget.draft.copyWith(
      content: body.isEmpty ? null : body,
      draft: false,
    );
  }
}
