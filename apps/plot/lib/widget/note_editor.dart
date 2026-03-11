import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';
import 'package:plot/util/string.dart';
import 'package:plot/state/thread.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform.dart';
import 'logging.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    required this.draft,
    this.flushToBottom = false,
    // New thread mode parameters (all null/default in note mode)
    this.thread,
    this.twists,
    this.actors,
    this.onDraftChanged,
    this.showScheduleActions = true,
    this.hint,
    this.additionalMentions,
    this.onSubmitted,
    this.assignNote = true,
    super.key,
  });

  final Note draft;
  final bool flushToBottom;

  /// When non-null, the editor operates in new-thread mode.
  final Thread? thread;
  final List<PriorityTwist>? twists;
  final List<Actor>? actors;
  final Future<void> Function(Thread thread, {Note? note})? onDraftChanged;

  /// Whether to show the To Do and Schedule action buttons in the bottom bar.
  /// Only used in new-thread mode.
  final bool showScheduleActions;

  /// Hint text shown in the editor when empty.
  /// Only used in new-thread mode (note mode derives hint from editing state).
  final String? hint;

  /// Additional actor IDs to include in the note's mentions on submit.
  /// Only used in new-thread mode.
  final List<ActorId>? additionalMentions;

  /// Called after the thread is submitted. Only used in new-thread mode.
  final VoidCallback? onSubmitted;

  /// Whether to assign the note to the current user when the thread is a todo.
  /// True for task-type threads, false for note/link/chat types with todo.
  final bool assignNote;

  bool get isNewThreadMode => thread != null;

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

  /// Twist IDs toggled OFF by the user for the current note.
  final Set<PriorityTwistId> _disabledTwists = {};

  void _resetDisabledTwists() {
    _disabledTwists.clear();
    if (widget.isNewThreadMode) return;
    final threadState = context.read<ThreadBloc>().state;
    for (final twist in threadState.threadTwists) {
      // Connectors that don't handle replies are never mentionable
      if (twist.isSource && !twist.defaultMentionCreated) continue;
      final isAuthor = threadState.notes.any(
        (n) => n.authorId.toUuid() == twist.id,
      );
      final shouldDefault = (isAuthor && twist.defaultMentionCreated) ||
          twist.defaultMentionMentioned;
      if (!shouldDefault) {
        _disabledTwists.add(twist.id);
      }
    }
  }

  /// Request focus on the editor
  void focus() {
    log.info(
      '[Focus] NoteEditor.focus() called: _editableAreaKey.currentState=${_editableAreaKey.currentState != null}',
    );
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

    // Reset editor and twist toggles if draft note ID changed
    if (newDraftNoteId != _lastDraftNoteId) {
      _resetDisabledTwists();
      if (widget.isNewThreadMode &&
          _lastDraftNoteId != null &&
          newDraftNoteId == null) {
        // Defer reset until after current frame to avoid modifying overlay during layout
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _editorKey.currentState?.reset(newContent);
          }
        });
      } else {
        _editorKey.currentState?.reset(newContent);
      }
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
    // Save draft when navigating away (unless finalized or editing)
    if (!_finalized && !_isEditing) {
      final editorState = _editorKey.currentState;
      if (editorState != null) {
        final content = editorState.serialize();
        _saveDraft(content);
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
        _saveDraft(content);
      }
    }
  }

  bool get _isEditing =>
      !widget.isNewThreadMode &&
      context.read<ThreadBloc>().state.editingNote != null;

  Future<void> _saveDraft(String content) async {
    if (_finalized) return;
    if (_isEditing) return;
    if (content == _lastSavedContent) return;

    if (widget.isNewThreadMode) {
      // New-thread mode: save via callback
      final existingNote = widget.draft.threadId == widget.thread!.id
          ? widget.draft
          : null;

      final Note note;
      if (existingNote != null) {
        note = existingNote.copyWith(content: content);
      } else {
        note = Note.draft(threadId: widget.thread!.id);
      }

      await widget.onDraftChanged!(widget.thread!, note: note);
    } else {
      // Note mode: save via ThreadBloc
      final activityBloc = context.read<ThreadBloc>();
      log.info('Saving draft note with content: $content');
      final updatedDraft = widget.draft.copyWith(content: content);
      await activityBloc.updateDraft(updatedDraft);
    }
    _lastSavedContent = content;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isNewThreadMode) {
      return _buildEditorArea(
        twists: widget.twists!,
        actors: widget.actors ?? const [],
      );
    }

    // Note mode: wrap with BlocListener (editing) and BlocBuilder (twists/actors)
    return BlocListener<ThreadBloc, ThreadState>(
      listenWhen: (prev, curr) => prev.editingNote != curr.editingNote,
      listener: (context, activityState) {
        if (activityState.editingNote != null) {
          // Load editing note content into editor
          _editorKey.currentState?.reset(
            activityState.editingNote!.content ?? '',
          );
          focus();
        } else {
          // Restore draft content
          _editorKey.currentState?.reset(widget.draft.content ?? '');
        }
      },
      child: BlocBuilder<PriorityBloc, PriorityState>(
        builder: (context, state) {
          return _buildEditorArea(twists: state.twists, actors: state.actors);
        },
      ),
    );
  }

  Widget _buildEditorArea({
    required List<PriorityTwist> twists,
    required List<Actor> actors,
  }) {
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

        final String hint;
        final bool isEditing;
        if (widget.isNewThreadMode) {
          hint = widget.hint ?? 'Start a new thread';
          isEditing = false;
        } else {
          final activityBloc = context.read<ThreadBloc>();
          final editingNote = activityBloc.state.editingNote;
          isEditing = editingNote != null;
          hint = isEditing ? 'Edit note' : 'Add a note';
        }

        final editor = Editor(
          key: _editorKey,
          hint: hint,
          autofocus: true,
          focusNode: focusNode,
          twists: twists,
          actors: actors,
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
          onChange: widget.isNewThreadMode
              ? (value) {
                  // Auto-save on content change in new-thread mode
                  _saveDraft(value);
                }
              : null,
          onSubmitted: widget.isNewThreadMode
              ? _onNewThreadSubmitted
              : _onNoteSubmitted,
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
              // Reply, editing, and twist indicators (note mode only)
              if (!widget.isNewThreadMode) _buildNoteIndicators(context),
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
                              _editorKey.currentState?.insertTextAtCursor(text);
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
              // Bottom bar
              if (widget.isNewThreadMode)
                _buildNewThreadBottomBar()
              else
                _buildNoteBottomBar(context),
            ],
          ),
        );
      },
    );
  }

  // -- Indicators (note mode only) --

  /// Wraps reply, editing, and twist indicators in a single builder so that
  /// empty indicators don't contribute spacing gaps in the parent Column.
  Widget _buildNoteIndicators(BuildContext context) {
    return BlocBuilder<ThreadBloc, ThreadState>(
      buildWhen: (prev, curr) =>
          prev.replyTo != curr.replyTo ||
          prev.editingNote != curr.editingNote ||
          prev.thread.mentions != curr.thread.mentions,
      builder: (context, state) {
        final indicators = <Widget>[
          if (state.replyTo != null)
            _buildReplyIndicatorContent(context, state.replyTo!),
          if (state.editingNote != null)
            _buildEditingIndicatorContent(context, state.editingNote!),
          if (state.editingNote == null && state.threadTwists.isNotEmpty)
            _buildTwistIndicatorContent(context, state.threadTwists),
        ];
        if (indicators.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: indicators,
        );
      },
    );
  }

  Widget _buildReplyIndicatorContent(BuildContext context, Note replyTo) {
    final raw = replyTo.content ?? '';
    final preview = raw.split('\n').first;
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6),
      child: Container(
        padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: context.colour.muted, width: 2),
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
                context.read<ThreadBloc>().setReplyTo(null);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
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
  }

  Widget _buildEditingIndicatorContent(BuildContext context, Note editingNote) {
    final raw = editingNote.content ?? '';
    final firstLine = raw.split('\n').first;
    final preview = firstLine.length > 60
        ? '${firstLine.substring(0, 60)}...'
        : firstLine;
    final activityBloc = context.read<ThreadBloc>();
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6),
      child: Container(
        padding: const EdgeInsets.only(left: 8, top: 4, bottom: 4),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: context.colour.accent, width: 2),
          ),
        ),
        child: Row(
          children: [
            Icon(
              FontAwesomeIcons.penToSquare,
              size: 10,
              color: context.colour.accent,
            ),
            const SizedBox(width: 6),
            Text(
              'Editing',
              style: context.theme.typography.xs.copyWith(
                color: context.colour.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
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
            Button.icon(
              CommandWrapper(
                EditNote(editingNote, activityBloc: activityBloc),
                title: 'Cancel editing',
                icon: Value(FontAwesomeIcons.xmark),
                run: (action, ctx) async {
                  activityBloc.setEditingNote(null);
                  return const CommandDone();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTwistIndicatorContent(
    BuildContext context,
    List<PriorityTwist> twists,
  ) {
    final mentionableTwists = twists
        .where((t) => !t.isSource || t.defaultMentionCreated)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final twist in mentionableTwists)
            _buildTwistToggleChip(context, twist),
        ],
      ),
    );
  }

  Widget _buildTwistToggleChip(BuildContext context, PriorityTwist twist) {
    final disabled = _disabledTwists.contains(twist.id);
    final isDark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final logoUrl = isDark && twist.logoUrlDark != null
        ? twist.logoUrlDark
        : twist.logoUrl;
    const chipRadius = BorderRadius.all(Radius.circular(24));
    const chipPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 4);

    return FButton(
      onPress: () {
        setState(() {
          if (disabled) {
            _disabledTwists.remove(twist.id);
          } else {
            _disabledTwists.add(twist.id);
          }
        });
      },
      style: disabled
          ? FButtonStyle.secondary(
              (s) => s.copyWith(
                decoration: _remapDecoration(s.decoration, chipRadius),
                contentStyle: (c) => c.copyWith(padding: chipPadding),
              ),
            )
          : FButtonStyle.primary(
              (s) => s.copyWith(
                decoration: _remapDecoration(s.decoration, chipRadius),
                contentStyle: (c) => c.copyWith(padding: chipPadding),
              ),
            ),
      mainAxisSize: MainAxisSize.min,
      prefix: logoUrl != null
          ? LogoImage(url: logoUrl, size: 12)
          : Icon(PlotIcon.twist, size: 12),
      child: Text(
        twist.name,
        style: disabled
            ? TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
    );
  }

  static FWidgetStateMap<BoxDecoration> _remapDecoration(
    FWidgetStateMap<BoxDecoration> source,
    BorderRadius radius,
  ) {
    BoxDecoration apply(BoxDecoration d) => d.copyWith(borderRadius: radius);

    return FWidgetStateMap({
      WidgetState.disabled: apply(source.resolve({WidgetState.disabled})),
      WidgetState.hovered | WidgetState.pressed: apply(
        source.resolve({WidgetState.hovered}),
      ),
      WidgetState.any: apply(source.resolve({})),
    });
  }

  // -- Bottom bars --

  Widget _buildNoteBottomBar(BuildContext context) {
    return BlocBuilder<ThreadBloc, ThreadState>(
      buildWhen: (prev, curr) => prev.editingNote != curr.editingNote,
      builder: (context, activityState) {
        final isCurrentlyEditing = activityState.editingNote != null;
        return Row(
          children: [
            if (!isCurrentlyEditing)
              IgnorePointer(
                ignoring: _saving,
                child: Opacity(
                  opacity: _saving ? 0.6 : 1.0,
                  child: Row(
                    children: [
                      // Left side: Add Task toggle
                      Button.icon(
                        ToggleSelfTask(widget.draft),
                        selected: widget.draft.isAssignedTo(Base.actorId),
                      ),
                      // Assign (only for shared priorities)
                      if (!context
                          .read<ThreadBloc>()
                          .state
                          .thread
                          .priority
                          .personal)
                        Button.icon(PickNoteAssignee(widget.draft)),
                      // Private toggle (only for shared priorities)
                      if (!context
                              .read<ThreadBloc>()
                              .state
                              .thread
                              .priority
                              .personal &&
                          (!widget.draft.private ||
                              widget.draft.authorId == Base.actorId))
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
                              .read<ThreadBloc>()
                              .state
                              .thread
                              .priority
                              .id
                              .toString(),
                          currentLinks: widget.draft.actions ?? const [],
                          onLinksChanged: (actions) {
                            final updatedDraft = widget.draft.copyWith(
                              actions: actions,
                            );
                            context.read<ThreadBloc>().updateDraft(
                              updatedDraft,
                            );
                          },
                        ),
                        selected:
                            widget.draft.actions?.any(
                              (l) => l.type == UserActionType.file,
                            ) ??
                            false,
                      ),
                      if (isMobilePlatform())
                        Button.icon(
                          TakePhoto(
                            priorityId: context
                                .read<ThreadBloc>()
                                .state
                                .thread
                                .priority
                                .id
                                .toString(),
                            currentLinks: widget.draft.actions ?? const [],
                            onLinksChanged: (actions) {
                              final updatedDraft = widget.draft.copyWith(
                                actions: actions,
                              );
                              context.read<ThreadBloc>().updateDraft(
                                updatedDraft,
                              );
                            },
                          ),
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
                      (widget.draft.actions?.any(
                            (l) => l.type == UserActionType.file,
                          ) ??
                          false)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNewThreadBottomBar() {
    final thread = widget.thread!;
    final draftNote = widget.draft;
    return Row(
      children: [
        IgnorePointer(
          ignoring: _saving,
          child: Opacity(
            opacity: _saving ? 0.6 : 1.0,
            child: Row(
              children: [
                if (widget.showScheduleActions && !thread.priority.isViewer) ...[
                  // Left side: Todo toggle (on == today)
                  Button.icon(
                    ToggleThreadToDo(
                      thread,
                      onUpdate: (t) => widget.onDraftChanged!(t),
                    ),
                    selected: thread.todo,
                  ),
                  // Schedule toggle (on == future date)
                  Builder(
                    builder: (context) {
                      final isScheduled = thread.isFuture;
                      return Button.icon(
                        isScheduled
                            ? CommandWrapper(
                                ThreadDone(
                                  thread,
                                  onUpdate: (t) => widget.onDraftChanged!(t),
                                ),
                                icon: Value(PlotIcon.schedule),
                              )
                            : PickScheduleThread(
                                thread,
                                onUpdate: (t) => widget.onDraftChanged!(t),
                              ),
                        selected: isScheduled,
                      );
                    },
                  ),
                ],
                if (!thread.priority.personal && !thread.private && !thread.priority.isViewer)
                  Button.icon(
                    ToggleThreadPrivate(
                      thread,
                      onUpdate: (t) => widget.onDraftChanged!(t),
                    ),
                    selected: thread.private,
                  ),
                if (!thread.priority.personal && !thread.priority.isViewer)
                  Button.icon(
                    PickDraftNoteAssignee(
                      note: draftNote,
                      priorityId: thread.priority.id,
                      onUpdate: (note) =>
                          widget.onDraftChanged!(thread, note: note),
                    ),
                  ),
                Button.icon(
                  AttachFile(
                    priorityId: thread.priority.id.toString(),
                    currentLinks: draftNote.actions ?? const [],
                    onLinksChanged: (actions) {
                      widget.onDraftChanged!(
                        thread,
                        note: draftNote.copyWith(actions: actions),
                      );
                    },
                  ),
                  selected:
                      draftNote.actions?.any(
                        (l) => l.type == UserActionType.file,
                      ) ??
                      false,
                ),
                if (isMobilePlatform())
                  Button.icon(
                    TakePhoto(
                      priorityId: thread.priority.id.toString(),
                      currentLinks: draftNote.actions ?? const [],
                      onLinksChanged: (actions) {
                        widget.onDraftChanged!(
                          thread,
                          note: draftNote.copyWith(actions: actions),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Spacer(),
        // Right side: Save button (always visible)
        Button.icon(
          CommandWrapper(
            AddThread(Future.value(thread)),
            run: (action, context) async {
              _editorKey.currentState?.submit(false);
              return const CommandDone();
            },
          ),
          style: ButtonStyle.primary,
          loading: _saving,
          enabled: !_saving && !_isEmpty,
        ),
      ],
    );
  }

  // -- Submit handlers --

  Future<void> _onNoteSubmitted(String body, {bool alt = false}) async {
    final activityBloc = context.read<ThreadBloc>();
    final editingNote = activityBloc.state.editingNote;

    if (editingNote != null) {
      // Editing mode: update the existing note
      setState(() {
        _saving = true;
      });
      try {
        final updatedNote = editingNote.copyWith(content: body);
        await activityBloc.updateNote(updatedNote);
        // Reset editor to draft content
        _editorKey.currentState?.reset(widget.draft.content ?? '');
      } finally {
        if (mounted) {
          setState(() {
            _saving = false;
          });
        }
      }
    } else {
      // Normal mode: add a new note
      final note = _finalizeNoteDraft(body, alt: alt);
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
    }
  }

  Future<void> _onNewThreadSubmitted(String body, {bool alt = false}) async {
    final data = await finalizeThreadDraft(
      body,
      twists: widget.twists!,
      alt: alt,
    );
    if (!mounted) return;
    setState(() {
      _saving = true;
    });

    widget.onSubmitted?.call();
    await context.run(AddThreadWithNote(data));
    if (mounted) {
      setState(() {
        _saving = false;
      });
    }
  }

  // -- Finalize methods --

  /// Returns the list of active (non-disabled) twist ActorIds from thread mentions.
  List<ActorId> _getActiveTwistMentions() {
    if (widget.isNewThreadMode) return const [];
    final threadState = context.read<ThreadBloc>().state;
    return threadState.threadTwists
        .where((t) => !t.isSource || t.defaultMentionCreated)
        .where((t) => !_disabledTwists.contains(t.id))
        .map((t) => ActorId.fromUuid(t.id))
        .toList();
  }

  Future<Note> _finalizeNoteDraft(String body, {bool alt = false}) async {
    _finalized = true;

    // Get replyTo from ThreadBloc state
    final activityBloc = context.read<ThreadBloc>();
    final replyTo = activityBloc.state.replyTo;

    // Merge active twist mentions into the note
    final activeTwistMentions = _getActiveTwistMentions();

    Note note = widget.draft.copyWith(
      content: body.isEmpty ? null : body,
      draft: false,
      reNoteId: replyTo?.id,
      addMentions: activeTwistMentions.isNotEmpty ? activeTwistMentions : null,
    );

    // If Cmd-Enter was pressed, assign the note to current user
    if (alt && !note.isAssignedTo(Base.actorId)) {
      note = note.assignTo(Base.actorId);
    }

    return note;
  }

  /// Kept public for note mode compatibility (ThreadPage calls this).
  Future<Note> finalizeDraft(String body, {bool alt = false}) =>
      _finalizeNoteDraft(body, alt: alt);

  Future<ThreadWithNote> finalizeThreadDraft(
    String body, {
    required List<PriorityTwist> twists,
    required bool alt,
  }) async {
    _finalized = true;

    // Generate title from body (first line or first ~50 chars)
    String title = body
        .trim()
        .split('\n')
        .first
        .trim()
        .removeMarkdown(replaceLinksWithURL: false);
    if (title.isEmpty) {
      title = 'Untitled';
    }
    log.info('Finalizing draft with title: $title');

    // Apply "Do Now" scheduling only if Cmd-Enter (alt) was used
    final shouldSchedule = alt;
    final hasDateTime = widget.thread!.at != null;

    // Create Thread with title based on "Do Now" toggle
    final thread = widget.thread!.copyWith(
      title: Value(title),
      preview: const Value(null),
      draft: false,
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
      note = widget.draft.copyWith(content: body);
    }

    // Merge additional mentions (e.g. selected twist for chat mode)
    if (widget.additionalMentions != null && note != null) {
      note = note.copyWith(
        mentions: [...?note.mentions, ...widget.additionalMentions!],
      );
    }

    return ThreadWithNote(
      thread: thread,
      note: note,
      assignNote: widget.assignNote,
    );
  }
}
