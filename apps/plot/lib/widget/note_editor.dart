import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';

import 'package:plot/state/thread.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/widget/note_editor_top_bar.dart';
import 'package:plot/widget/recipient_picker_modal.dart';
import 'package:plot/command/command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/image_utils.dart';
import 'package:plot/util/link_type_copy.dart';
import 'package:plot/util/shortcut.dart';
import 'package:plot/api/api.dart' as api;
import 'package:plot/api/network_exception.dart';
import 'package:plot/util/url_title.dart';
import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/style/button.dart' show ghostSizedStyleDelta;
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'logging.dart';

class NoteEditor extends StatefulWidget {
  const NoteEditor({
    required this.draft,
    this.flushToBottom = false,
    // New thread mode parameters (all null/default in note mode)
    this.thread,
    this.onDraftChanged,
    this.showScheduleActions = true,
    this.hint,
    this.sendLabel,
    this.additionalMentions,
    this.onSubmitted,
    this.submitValidator,
    this.viewerMode = false,
    // Twist selection (new-thread mode)
    this.selectedTwist,
    this.onTwistSelected,
    this.onTwistMentioned,
    // Link/navigation callbacks
    this.onNavigateToThread,
    this.autofocus,
    this.bodyOnly = false,
    super.key,
  });

  final Note draft;
  final bool flushToBottom;

  /// When non-null, the editor operates in new-thread mode.
  final Thread? thread;
  final Future<void> Function(Thread thread, {Note? note})? onDraftChanged;

  /// Whether to show the To Do and Schedule action buttons in the bottom bar.
  /// Only used in new-thread mode.
  final bool showScheduleActions;

  /// Hint text shown in the editor when empty.
  /// Only used in new-thread mode (note mode derives hint from editing state).
  final String? hint;

  /// Label for the primary Save/Send button in new-thread mode.
  /// When null the button falls back to the [AddThread] command's default title.
  /// Only used in new-thread mode.
  final String? sendLabel;

  /// Additional actor IDs to include in the note's mentions on submit.
  /// Only used in new-thread mode.
  final List<ActorId>? additionalMentions;

  /// Called after the thread is submitted. Only used in new-thread mode.
  final VoidCallback? onSubmitted;

  /// Optional pre-submit validation hook for new-thread mode.
  ///
  /// Called at the start of `_onNewThreadSubmitted` before any writes.
  /// Return a non-null [String] to block submission — the string is shown
  /// to the user as an error toast. Return null to allow submission to
  /// proceed normally.
  final String? Function()? submitValidator;

  /// When true, hides all toolbar controls for viewer-created content in
  /// readonly priorities. Notes are auto-private.
  final bool viewerMode;

  /// Currently selected twist (new-thread mode). Button shows selected state.
  final TwistInstance? selectedTwist;

  /// Called when user selects a twist from the picker modal.
  final ValueChanged<TwistInstance>? onTwistSelected;

  /// Called when the user completes an @-mention of a twist in the editor
  /// body. Parent should treat as a connection-target pick (parallel to
  /// the contact-mention → add-to-thread behavior). The mention text is
  /// still inserted; this is an additive signal.
  final void Function(String twistId)? onTwistMentioned;

  /// Called when user selects an existing thread from the link modal.
  final void Function(Thread thread)? onNavigateToThread;

  /// Override the editor's default autofocus behavior. When null, the editor
  /// autofocuses in new-thread mode or when a physical keyboard is present.
  final bool? autofocus;

  /// Skip the outer EditableArea wrapper. Used when an ancestor already
  /// provides the bordered surface (e.g. NewThreadPage's compose card).
  final bool bodyOnly;

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
  // Used only when widget.bodyOnly is true. EditableArea owns the
  // FocusNode in the normal path; here we own it.
  FocusNode? _bodyOnlyFocusNode;
  // Tracks the most recent in-flight _saveDraft. Submit handlers await this
  // before publishing so the publish can't race with a keystroke-triggered
  // save that already passed the _finalized check.
  Future<void>? _pendingDraftSave;

  /// Working copy of attachments while editing an existing note. Null when
  /// not editing — in that case attachments come from `widget.draft.actions`.
  /// On submit, this list replaces the edited note's actions.
  List<UserAction>? _editingActions;

  /// Attachments to render and operate on. While editing, that's the
  /// in-progress copy; otherwise it's the draft note's actions.
  List<UserAction> get _currentActions {
    if (_editingActions != null) return _editingActions!;
    return widget.draft.actions ?? const <UserAction>[];
  }

  /// Persists a new attachment list to the right place: the in-memory editing
  /// copy, the new-thread draft, or the note-mode draft.
  void _setCurrentActions(List<UserAction> actions) {
    if (_editingActions != null) {
      setState(() {
        _editingActions = actions;
      });
      return;
    }
    if (widget.isNewThreadMode) {
      widget.onDraftChanged!(
        widget.thread!,
        note: widget.draft.copyWith(actions: actions),
      );
      return;
    }
    context.read<ThreadBloc>().updateDraft(
      widget.draft.copyWith(actions: actions),
    );
  }

  /// Resolved autofocus: the value handed to the inner [Editor]. New-thread
  /// editors and physical-keyboard platforms autofocus by default; callers can
  /// override via [NoteEditor.autofocus] (e.g. a note-mode editor on a touch
  /// platform passes nothing and resolves to false, so the soft keyboard isn't
  /// forced up). The `bodyOnly` focus recovery is gated on this.
  bool get _shouldAutofocus =>
      widget.autofocus ?? (widget.isNewThreadMode || hasPhysicalKeyboard());

  /// Request focus on the editor
  void focus() {
    log.info(
      '[Focus] NoteEditor.focus() called: _editableAreaKey.currentState=${_editableAreaKey.currentState != null}',
    );
    if (widget.bodyOnly) {
      _bodyOnlyFocusNode?.requestFocus();
    } else {
      _editableAreaKey.currentState?.focus();
    }
  }

  /// Drops focus from the editor when it currently holds it, returning whether
  /// it did. The new-thread compose surface calls this from its Escape handler:
  /// SuperEditor lets Escape bubble unhandled and the page's global Escape
  /// handler would otherwise re-focus the editor, so the Escape handler blurs
  /// via this method and consumes the event before it reaches that handler.
  bool unfocus() {
    final node = _currentFocusNode;
    if (node != null && node.hasFocus) {
      node.unfocus();
      return true;
    }
    return false;
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

    // Reset editor when draft note ID changes — but skip the SuperEditor
    // reset if the new content matches what's already in the editor. During
    // initial load the PriorityBloc rebuilds the draft note several times
    // (chain draft lookup, background note load) and each emit produces a
    // fresh Note id even when the underlying content is unchanged. A reset()
    // call triggers a setState inside the SuperEditor that briefly clears
    // and re-renders the document — visible as a flicker.
    if (newDraftNoteId != _lastDraftNoteId) {
      if (newContent != _lastSavedContent) {
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
    _bodyOnlyFocusNode?.dispose();
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

  /// Whether the editor's text input currently has primary focus.
  bool get hasFocus => _currentFocusNode?.hasFocus ?? false;

  /// Whether the editor has no content. Reflects the latest
  /// `onIsEmptyChanged` callback from the underlying [Editor].
  bool get isEmpty => _isEmpty;

  /// Handle an image pasted from clipboard: insert a placeholder attachment
  /// immediately (so the preview appears without waiting on the network) and
  /// upload in the background, swapping the placeholder for the real
  /// attachment once the server returns the file id.
  Future<void> _handleImagePaste(Uint8List imageBytes) async {
    final priorityId = widget.isNewThreadMode
        ? widget.thread!.priority.id.toString()
        : context.read<ThreadBloc>().state.thread.priority.id.toString();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'pasted-image-$timestamp.png';
    final pendingFileId = '__pending_$timestamp';

    final dims = await getImageDimensions(imageBytes);
    if (!mounted) return;
    final imageWidth = dims?.$1;
    final imageHeight = dims?.$2;

    final placeholder = FileUserAction(
      fileId: pendingFileId,
      fileName: fileName,
      fileSize: imageBytes.lengthInBytes,
      mimeType: 'image/png',
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );

    FilePreviewCache.put(pendingFileId, imageBytes);
    _setCurrentActions([..._currentActions, placeholder]);

    try {
      final response = await api.uploadFile(
        filePath: '',
        fileName: fileName,
        priorityId: priorityId,
        bytes: imageBytes,
      );

      if (!mounted) {
        FilePreviewCache.evict(pendingFileId);
        return;
      }

      final realFileId = response['fileId'] as String;
      final realAction = FileUserAction(
        fileId: realFileId,
        fileName: response['fileName'] as String,
        fileSize: response['fileSize'] as int,
        mimeType: response['mimeType'] as String,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );

      FilePreviewCache.rekey(pendingFileId, realFileId);

      final actions = _currentActions;
      var replaced = false;
      final updated = actions.map((a) {
        if (!replaced && a is FileUserAction && a.fileId == pendingFileId) {
          replaced = true;
          return realAction;
        }
        return a;
      }).toList();
      if (!replaced) {
        // The user removed the placeholder mid-upload — drop the cached bytes
        // and the just-uploaded file is orphaned (server-side cleanup, not
        // ours to manage here).
        FilePreviewCache.evict(realFileId);
        return;
      }
      _setCurrentActions(updated);
    } on NetworkException {
      _removePendingAttachment(pendingFileId);
      if (mounted) {
        context.showToast(
          message: "You're offline. Please try again when connected.",
          isError: true,
        );
      }
    } catch (e, t) {
      _removePendingAttachment(pendingFileId);
      log.warning('Failed to upload pasted image', e, t);
      Tracker.captureException(e, t);
      if (mounted) {
        context.showToast(
          message: 'Failed to upload pasted image.',
          isError: true,
        );
      }
    }
  }

  void _removePendingAttachment(String pendingFileId) {
    FilePreviewCache.evict(pendingFileId);
    if (!mounted) return;
    final actions = _currentActions;
    final filtered = actions
        .where((a) => !(a is FileUserAction && a.fileId == pendingFileId))
        .toList();
    if (filtered.length == actions.length) return;
    _setCurrentActions(filtered);
  }

  /// Handle a URL pasted into an otherwise empty editor: attach it as an
  /// `ExternalUserAction` (the same shape the link command produces) and
  /// asynchronously resolve title and favicon to update the placeholder.
  Future<void> _handleUrlPasteWhenEmpty(String url) async {
    final placeholder = ExternalUserAction(title: url, url: url);
    _setCurrentActions([..._currentActions, placeholder]);

    final metadata = await fetchUrlMetadata(url);
    if (!mounted) return;
    if (metadata.title == null && metadata.favicon == null) return;

    final actions = _currentActions;
    final resolved = ExternalUserAction(
      title: metadata.title ?? url,
      url: url,
      favicon: metadata.favicon,
    );
    var replaced = false;
    final updated = actions.map((a) {
      if (!replaced && a == placeholder) {
        replaced = true;
        return resolved;
      }
      return a;
    }).toList();
    if (!replaced) return;
    _setCurrentActions(updated);
  }

  Future<void> _saveDraft(String content) async {
    if (_finalized) return;
    if (_isEditing) return;
    if (content == _lastSavedContent) return;

    final updatedNote = widget.draft.copyWith(content: content);

    final Future<void> task;
    if (widget.isNewThreadMode) {
      task = widget.onDraftChanged!(widget.thread!, note: updatedNote);
    } else {
      final activityBloc = context.read<ThreadBloc>();
      log.info('Saving draft note with content: $content');
      task = activityBloc.updateDraft(updatedNote);
    }
    _pendingDraftSave = task;
    try {
      await task;
      _lastSavedContent = content;
    } finally {
      if (identical(_pendingDraftSave, task)) _pendingDraftSave = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isNewThreadMode) {
      // Subscribe to PriorityBloc internally so the parent NewThreadPage
      // doesn't have to include `twists`/`actors` in its BlocBuilder
      // buildWhen. Without this isolation, every emit of the Drift actors
      // stream during initial sync (many in production with lots of
      // contacts) would rebuild the entire chip row + scaffold above this
      // editor. With this internal subscription, only the Editor subtree
      // rebuilds on twists/actors changes.
      return BlocBuilder<PriorityBloc, PriorityState>(
        buildWhen: (prev, curr) =>
            prev.twists != curr.twists || prev.actors != curr.actors,
        builder: (context, state) {
          return _buildEditorArea(twists: state.twists, actors: state.actors);
        },
      );
    }

    // Note mode: wrap with BlocListener (editing) and BlocBuilder (twists/actors)
    return BlocListener<ThreadBloc, ThreadState>(
      listenWhen: (prev, curr) =>
          prev.editingNote != curr.editingNote || prev.replyTo != curr.replyTo,
      listener: (context, activityState) {
        if (activityState.editingNote != null) {
          // Seed the working attachment list from the note being edited.
          setState(() {
            _editingActions = List.of(
              activityState.editingNote!.actions ?? const <UserAction>[],
            );
          });
          // Load editing note content into editor
          _editorKey.currentState?.reset(
            activityState.editingNote!.content ?? '',
          );
          focus();
        } else if (activityState.replyTo != null) {
          if (_editingActions != null) {
            setState(() {
              _editingActions = null;
            });
          }
          focus();
        } else {
          if (_editingActions != null) {
            setState(() {
              _editingActions = null;
            });
          }
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
    required List<TwistInstance> twists,
    required List<Actor> actors,
  }) {
    Widget buildContent(BuildContext context, FocusNode focusNode) {
      // Set up focus listener once
      if (_currentFocusNode != focusNode) {
        _currentFocusNode?.removeListener(_onFocusChange);
        _currentFocusNode = focusNode;
        _currentFocusNode?.addListener(_onFocusChange);
      }

      final String hint;
      if (widget.isNewThreadMode) {
        hint = widget.hint ?? 'Start a new thread';
      } else {
        hint = _resolvePlaceholder();
      }

      // Contacts already on this thread are surfaced first in @-mention
      // suggestions. In new-thread mode the draft thread is the source; in
      // note mode it's the live thread from ThreadBloc. `thread.contacts`
      // can include non-primary aliases for the same person, so collapse
      // each to its canonical actor id before matching against `actors`
      // (which is loaded with `primary: true`).
      final Thread? mentionThread = widget.isNewThreadMode
          ? widget.thread
          : context.read<ThreadBloc>().state.thread;
      final Set<String> threadContactIds = mentionThread == null
          ? const <String>{}
          : mentionThread.activeContacts
                .map((u) => Actor.canonicalId(ActorId.fromUuid(u)).toString())
                .toSet();

      final editor = Editor(
        key: _editorKey,
        hint: hint,
        autofocus: _shouldAutofocus,
        focusNode: focusNode,
        twists: twists,
        actors: actors,
        threadContactIds: threadContactIds,
        shrinkWrap: true,
        initialContent: widget.draft.content,
        onTwistMentioned: widget.onTwistMentioned,
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
        onImagePasted: (imageBytes) => _handleImagePaste(imageBytes),
        onUrlPastedWhenEmpty: (url) => _handleUrlPasteWhenEmpty(url),
      );

      return CallbackShortcuts(
        bindings: _buildNoteShortcuts(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top bar: pill row (note-type chooser) or takeover bar
            // (reply / editing chrome). Hidden in new-thread mode — the top
            // chrome there lives in NewThreadPage.
            if (!widget.isNewThreadMode) _buildTopBar(context),
            Flexible(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 12,
                  right: 12,
                  top: 4,
                  bottom:
                      12 +
                      (widget.flushToBottom
                          ? MediaQuery.paddingOf(context).bottom
                          : 0),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 4,
                  children: [
                    _buildAttachmentRows(),
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
                                  child: ScrollEdgeFade(
                                    background: context
                                        .theme
                                        .plotColors
                                        .editableBackground,
                                    child: editor,
                                  ),
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
                    if (widget.isNewThreadMode)
                      _buildNewThreadBottomBar()
                    else
                      _buildNoteBottomBar(context),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (widget.bodyOnly) {
      final focusNode = _bodyOnlyFocusNode ??= FocusNode();
      // bodyOnly skips EditableArea (and its focus recovery), so SuperEditor's
      // one-shot autofocus is the only thing focusing this editor — and it
      // loses to the navigator's post-route focus pass / macOS's clear-to-root.
      // AutofocusReclaim re-grabs focus across a few frames when nobody owns it.
      return AutofocusReclaim(
        focusNode: focusNode,
        autofocus: _shouldAutofocus,
        child: Builder(builder: (context) => buildContent(context, focusNode)),
      );
    }

    return EditableArea(
      key: _editableAreaKey,
      padding: false,
      position: EditableAreaPosition.bottom,
      flushToBottom: widget.flushToBottom,
      builder: buildContent,
    );
  }

  // -- Top bar (note mode only) --

  /// Note-mode top region. Renders either the pill row (note-type chooser)
  /// or the loud takeover chrome for reply / editing flows. State + draft
  /// drive which pills are shown and which one is active; the placeholder
  /// and Send-button label derive from the same active pill.
  Widget _buildTopBar(BuildContext context) {
    return BlocBuilder<ThreadBloc, ThreadState>(
      buildWhen: (prev, curr) =>
          prev.replyTo != curr.replyTo ||
          prev.editingNote != curr.editingNote ||
          prev.draft != curr.draft ||
          prev.thread != curr.thread ||
          prev.links != curr.links,
      builder: (context, state) {
        final threadBloc = context.read<ThreadBloc>();
        return NoteEditorTopBar(
          state: _computeTopBarState(state),
          onClearReply: () => threadBloc.setReplyTo(null),
          onCancelEdit: () => threadBloc.setEditingNote(null),
        );
      },
    );
  }

  /// Single-line preview of a quoted note's content, capped at 60 chars.
  String _previewOf(String? content) {
    if (content == null || content.isEmpty) return '';
    final firstLine = content.split('\n').first;
    return firstLine.length > 60
        ? '${firstLine.substring(0, 60)}...'
        : firstLine;
  }

  TopBarState _computeTopBarState(ThreadState s) {
    final replyTo = s.replyTo;
    if (replyTo != null) {
      return ReplyingState(quotePreview: _previewOf(replyTo.content));
    }
    final editingNote = s.editingNote;
    if (editingNote != null) {
      return EditingState(quotePreview: _previewOf(editingNote.content));
    }
    return PillRowState(pills: _buildPills(s), activeId: _activePillId(s));
  }

  /// Whether any of the user's linked actors matches the candidate. Threads
  /// can list contacts under any of the user's email aliases, so canonical
  /// identity is used for matching against [Base.actorId].
  bool _isSelfContact(Uuid contactId) {
    final selfIds = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    return selfIds.contains(contactId);
  }

  /// Contact ids we've already kicked off an [Actor] cache warm for, so a
  /// rebuild doesn't re-request the same contacts every frame.
  final Set<Uuid> _avatarWarmRequested = {};

  /// Resolves the avatar cluster for the "Reply" pill: drawable [Actor]s for
  /// every other thread contact (excluding self / aliases of self), plus the
  /// total audience size (those contacts + every group) for the "+N" overflow.
  ///
  /// Returns an empty audience when there's only one recipient — the "Reply"
  /// label alone already conveys who's being replied to. Contacts not yet in
  /// the [Actor] cache aren't drawn individually but still count toward the
  /// total; [_warmAvatarCache] fetches them and rebuilds so they appear.
  ({List<Actor> actors, int total}) _replyAudience(Thread thread) {
    final nonSelf = thread.activeContacts
        .where((c) => !_isSelfContact(c))
        .toList();
    final total = nonSelf.length + thread.groups.length;
    if (total < 2) return (actors: const [], total: 0);
    _warmAvatarCache(nonSelf);
    final actors = <Actor>[];
    for (final c in nonSelf) {
      final a = Actor.fromCache(ActorId.fromUuid(c));
      if (a != null) actors.add(a);
    }
    return (actors: actors, total: total);
  }

  /// Drawable single-avatar list for a contact (e.g. the "Reply to original"
  /// pill). Empty until the actor is cached; warms the cache otherwise.
  List<Actor> _singleAvatar(Uuid contactId) {
    final a = Actor.fromCache(ActorId.fromUuid(contactId));
    if (a != null) return [a];
    _warmAvatarCache([contactId]);
    return const [];
  }

  /// Fetches any uncached [Actor]s for [contactIds] in the background and
  /// rebuilds once they land, so avatar clusters resolve on first paint even
  /// when the thread's contacts weren't eagerly loaded into the cache.
  void _warmAvatarCache(Iterable<Uuid> contactIds) {
    final missing = <Uuid>[];
    for (final id in contactIds) {
      if (Actor.fromCache(ActorId.fromUuid(id)) != null) continue;
      if (!_avatarWarmRequested.add(id)) continue; // already requested
      missing.add(id);
    }
    if (missing.isEmpty) return;
    unawaited(() async {
      var anyResolved = false;
      for (final id in missing) {
        try {
          await Actor.getOne(ActorId.fromUuid(id));
          anyResolved = true;
        } catch (_) {
          // Unresolvable contact — leave it folded into the "+N" overflow.
          // We deliberately keep it in [_avatarWarmRequested] (no retry): a
          // retry that re-fires setState on every failure would loop forever
          // for a contact the cache can never resolve.
        }
      }
      // Only rebuild when an avatar actually became available — a warm where
      // everything failed wouldn't change the rendered cluster.
      if (anyResolved && mounted) setState(() {});
    }());
  }

  /// Returns the original-thread author when the "Reply to original" pill
  /// should be visible: original author isn't the current user AND the
  /// thread has 2+ other people. Returns the author UUID (a contact UUID)
  /// or null when the pill should not appear.
  Uuid? _originalAuthorIfDistinct(ThreadState s) {
    final firstNote = s.notes.isNotEmpty ? s.notes.first : null;
    if (firstNote == null) return null;
    final authorUuid = firstNote.authorId.toUuid();
    if (_isSelfContact(authorUuid)) return null;
    final otherCount = s.thread.activeContacts
        .where((c) => !_isSelfContact(c))
        .length;
    if (otherCount < 2) return null;
    return authorUuid;
  }

  /// Display name for a contact UUID. Falls back to "them" when the cache
  /// can't resolve it.
  String _displayName(Uuid contactId) {
    final actor = Actor.fromCache(ActorId.fromUuid(contactId));
    if (actor == null) return 'them';
    return actor.nameOrEmail;
  }

  /// Resolves the active pill id for the current state. The same value
  /// drives placeholder and Send-button copy.
  String _activePillId(ThreadState s) {
    final draft = widget.draft;
    if (draft.isPrivate) return 'private';
    if (_hasMentionableTwist(s)) return 'reply';
    if (draft.isAssignedTo(Base.actorId)) return 'task';
    final cfg = s.primaryLinkTypeConfig;
    final isPlotThread = cfg == null;
    final hasSharing =
        s.thread.activeContacts.where((c) => !_isSelfContact(c)).isNotEmpty ||
        s.thread.groups.isNotEmpty;
    if (isPlotThread) return hasSharing ? 'reply' : 'note';
    switch (cfg.sharingModel) {
      case SharingModel.message:
        return 'reply';
      case SharingModel.channel:
      case SharingModel.thread:
      case SharingModel.none:
        return 'comment';
    }
  }

  /// True when the thread has a non-source twist (e.g. Plot AI) the user
  /// is chatting with. Source connectors (Gmail, Slack) don't count —
  /// those keep their existing connector pill structure.
  bool _hasMentionableTwist(ThreadState s) =>
      s.threadTwists.any((t) => !t.isSource);

  List<TopBarPill> _buildPills(ThreadState s) {
    final pills = <TopBarPill>[];
    final cfg = s.primaryLinkTypeConfig;
    final isPlotThread = cfg == null;
    final hasSharing =
        s.thread.activeContacts.where((c) => !_isSelfContact(c)).isNotEmpty ||
        s.thread.groups.isNotEmpty;

    if (_hasMentionableTwist(s)) {
      final replyAudience = _replyAudience(s.thread);
      pills.add(
        TopBarPill(
          id: 'reply',
          label: 'Reply',
          avatarActors: replyAudience.actors,
          avatarTotalCount: replyAudience.total,
          onTap: _activatePlotReply,
          onAvatarsTap: hasSharing ? _openRecipientPicker : null,
        ),
      );
      pills.add(
        TopBarPill(
          id: 'private',
          label: 'Private note',
          onTap: _activatePrivate,
        ),
      );
      return pills;
    }

    if (isPlotThread) {
      if (!hasSharing) {
        // Unshared Plot thread: just Note / Task.
        pills.add(
          TopBarPill(id: 'note', label: 'Note', onTap: _activatePlotNote),
        );
        pills.add(
          TopBarPill(id: 'task', label: 'Task', onTap: _activatePlotTask),
        );
        return pills;
      }

      // Shared Plot thread.
      final replyAudience = _replyAudience(s.thread);
      pills.add(
        TopBarPill(
          id: 'reply',
          label: 'Reply',
          avatarActors: replyAudience.actors,
          avatarTotalCount: replyAudience.total,
          onTap: _activatePlotReply,
          onAvatarsTap: _openRecipientPicker,
        ),
      );
      final orig = _originalAuthorIfDistinct(s);
      if (orig != null) {
        pills.add(
          TopBarPill(
            id: 'replyOriginal',
            label: 'Reply to ${_displayName(orig)}',
            avatarActors: _singleAvatar(orig),
            avatarTotalCount: 1,
            onTap: () => _activateReplyToOriginal(orig),
            onAvatarsTap: _openRecipientPicker,
          ),
        );
      }
      pills.add(
        TopBarPill(id: 'task', label: 'Task', onTap: _activatePlotTask),
      );
      pills.add(
        TopBarPill(
          id: 'private',
          label: 'Private note',
          onTap: _activatePrivate,
        ),
      );
      return pills;
    }

    // Connector-backed thread.
    final noteLabel = cfg.noteLabel ?? 'Note';
    switch (cfg.sharingModel) {
      case SharingModel.message:
        final replyAudience = _replyAudience(s.thread);
        pills.add(
          TopBarPill(
            id: 'reply',
            label: cfg.noteLabel ?? 'Reply',
            avatarActors: replyAudience.actors,
            avatarTotalCount: replyAudience.total,
            onTap: _activateConnectorReply,
            onAvatarsTap: _openRecipientPicker,
          ),
        );
        final orig = _originalAuthorIfDistinct(s);
        if (orig != null) {
          pills.add(
            TopBarPill(
              id: 'replyOriginal',
              label: 'Reply to ${_displayName(orig)}',
              avatarActors: _singleAvatar(orig),
              avatarTotalCount: 1,
              onTap: () => _activateReplyToOriginal(orig),
              onAvatarsTap: _openRecipientPicker,
            ),
          );
        }
        pills.add(
          TopBarPill(
            id: 'private',
            label: 'Private note',
            onTap: _activatePrivate,
          ),
        );
        return pills;
      case SharingModel.channel:
      case SharingModel.thread:
      case SharingModel.none:
        pills.add(
          TopBarPill(
            id: 'comment',
            label: noteLabel,
            onTap: _activateConnectorReply,
          ),
        );
        pills.add(
          TopBarPill(
            id: 'private',
            label: 'Private note',
            onTap: _activatePrivate,
          ),
        );
        return pills;
    }
  }

  // -- Pill activation handlers --

  /// Returns the canonical "thread default" draft: not assigned to the
  /// current user (Task off) and accessContacts/accessGroups cleared so
  /// the audience is the whole thread.
  Note _draftAsThreadDefault() {
    var draft = widget.draft;
    if (draft.isAssignedTo(Base.actorId)) {
      draft = draft.toggleTag(Tag.todo, Base.actorId);
    }
    draft = draft.copyWith(
      accessContacts: const Value(null),
      accessGroups: const Value(null),
    );
    return draft;
  }

  void _activatePlotNote() {
    final draft = _draftAsThreadDefault();
    context.read<ThreadBloc>().updateDraft(draft);
  }

  void _activatePlotTask() {
    // Toggle on Tag.todo for the current user. Clear access constraints so
    // the task is visible to the whole thread (matches the previous
    // ToggleSelfTask UX in the bottom bar).
    var draft = widget.draft;
    if (!draft.isAssignedTo(Base.actorId)) {
      draft = draft.toggleTag(Tag.todo, Base.actorId);
    }
    draft = draft.copyWith(
      accessContacts: const Value(null),
      accessGroups: const Value(null),
    );
    context.read<ThreadBloc>().updateDraft(draft);
  }

  void _activatePlotReply() {
    context.read<ThreadBloc>().updateDraft(_draftAsThreadDefault());
  }

  void _activateConnectorReply() {
    context.read<ThreadBloc>().updateDraft(_draftAsThreadDefault());
  }

  void _activateReplyToOriginal(Uuid originalAuthor) {
    context.read<ThreadBloc>().setDraftRecipients(
      accessContacts: [Base.actorId, ActorId.fromUuid(originalAuthor)],
      accessGroups: const [],
    );
  }

  void _activatePrivate() {
    context.read<ThreadBloc>().setDraftRecipients(
      accessContacts: [Base.actorId],
      accessGroups: const [],
    );
  }

  Future<void> _openRecipientPicker() async {
    final bloc = context.read<ThreadBloc>();
    final s = bloc.state;
    final draft = widget.draft;
    final self = Base.actorId;
    final orig = _originalAuthorIfDistinct(s);

    final picker = RecipientPickerModal(
      threadContacts: s.thread.activeContacts.map((c) => c.toString()).toList(),
      threadGroups: s.thread.groups.map((g) => g.toString()).toList(),
      initialContactSelection:
          (draft.accessContacts?.map((a) => a.toUuid().toString()).toList()) ??
          s.thread.activeContacts.map((c) => c.toString()).toList(),
      initialGroupSelection:
          (draft.accessGroups?.map((a) => a.toUuid().toString()).toList()) ??
          s.thread.groups.map((g) => g.toString()).toList(),
      self: self.toString(),
      originalAuthor: orig?.toString(),
    );

    final result = await picker.run(context);
    if (result == null) return;
    if (!mounted) return;
    await bloc.editNoteRecipients(
      accessContacts: result.accessContacts?.map(ActorId.fromString).toList(),
      accessGroups: result.accessGroups?.map(ActorId.fromString).toList(),
      threadContactsAdded: result.threadContactsAdded
          .map(ActorId.fromString)
          .toList(),
      threadGroupsAdded: result.threadGroupsAdded
          .map(ActorId.fromString)
          .toList(),
    );
  }

  // -- Placeholder + Send label --

  /// Computes the editor placeholder from the active pill / takeover state.
  /// Falls back to the existing connector-aware helpers when the active
  /// pill doesn't have a dedicated string.
  String _resolvePlaceholder() {
    final s = context.read<ThreadBloc>().state;
    final cfg = s.primaryLinkTypeConfig;
    if (s.editingNote != null) return composerHintForEditNote(cfg);
    if (s.replyTo != null) return composerHintForNote(cfg);
    final pillId = _activePillId(s);
    switch (pillId) {
      case 'note':
        return 'Add a note';
      case 'task':
        return 'Add a task';
      case 'reply':
        if (cfg == null) return 'Reply';
        return cfg.replyPlaceholder?.isNotEmpty == true
            ? cfg.replyPlaceholder!
            : composerHintForNote(cfg);
      case 'replyOriginal':
        return 'Reply';
      case 'comment':
        return composerHintForNote(cfg);
      case 'private':
        return 'Add a private note';
      default:
        return composerHintForNote(cfg);
    }
  }

  /// Note-mode Send button label. New-thread mode is unaffected — that
  /// path already uses [NoteEditor.sendLabel] in [_buildNewThreadBottomBar].
  String _sendLabelForState(ThreadState s) {
    if (widget.sendLabel != null) return widget.sendLabel!;
    final cfg = s.primaryLinkTypeConfig;
    final pillId = _activePillId(s);
    switch (pillId) {
      case 'note':
        return 'Save';
      case 'task':
        return 'Save task';
      case 'reply':
        return cfg == null ? 'Send' : composerVerbForNote(cfg);
      case 'replyOriginal':
        return 'Send';
      case 'comment':
        return composerVerbForNote(cfg);
      case 'private':
        return 'Save';
      default:
        return 'Send';
    }
  }

  // -- Attachment rows (both modes) --

  /// Renders attached files and links as compact rows with an X to remove.
  Widget _buildAttachmentRows() {
    final actions = _currentActions;
    if (actions.isEmpty) return const SizedBox.shrink();

    // In new-thread mode the connection chip above the editor owns the
    // CreateLinkUserAction — surfacing it again here would be redundant
    // (and the user can't remove it from this row anyway since switching
    // back to "Plot thread" is done via the compose field).
    final attachments = actions
        .where(
          (a) =>
              a.type == UserActionType.file ||
              a.type == UserActionType.external ||
              (a.type == UserActionType.createLink && !widget.isNewThreadMode),
        )
        .toList();
    if (attachments.isEmpty) return const SizedBox.shrink();

    // Render create-link rows first so the "new link being created" is
    // visually prominent.
    attachments.sort((a, b) {
      final aCreate = a is CreateLinkUserAction ? 0 : 1;
      final bCreate = b is CreateLinkUserAction ? 0 : 1;
      return aCreate.compareTo(bCreate);
    });

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in attachments) _buildAttachmentRow(action),
        ],
      ),
    );
  }

  Widget _buildAttachmentRow(UserAction action) {
    if (action is CreateLinkUserAction) return _buildCreateLinkRow(action);

    final Widget icon;
    final String label;
    final bool isImageThumb = action is FileUserAction && action.isImage;

    if (action is FileUserAction) {
      icon = action.isImage
          ? FileImageThumbnail(link: action, size: 28)
          : Icon(PlotIcon.attachment, size: 12, color: context.colour.muted);
      label = action.fileName;
    } else if (action is ExternalUserAction) {
      final favicon = action.favicon;
      icon = favicon != null
          ? LogoImage(
              url: favicon,
              size: 12,
              fallback: Icon(
                PlotIcon.link,
                size: 12,
                color: context.colour.muted,
              ),
            )
          : Icon(PlotIcon.link, size: 12, color: context.colour.muted);
      label = action.title;
    } else {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          icon,
          SizedBox(width: isImageThumb ? 8 : 6),
          Expanded(
            child: Text(
              label,
              style: context.theme.typography.xs.copyWith(
                color: context.colour.muted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _removeAttachment(action),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Icon(
                FontAwesomeIcons.xmark,
                size: 12,
                color: context.colour.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Row for a `CreateLinkUserAction`: connector logo, "Create new [Type]
  /// (account)", trailing ghost-button status selector, then remove button.
  Widget _buildCreateLinkRow(CreateLinkUserAction action) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final logo = isDark ? (action.logoDark ?? action.logo) : action.logo;

    // Resolve the link type config to source status options. Channel-level
    // statuses take precedence for the picker, but the current status may be
    // a twist-level default (e.g. a category like "unstarted" when the
    // channel stores state UUIDs from a stale sync) so the label lookup
    // consults both.
    final twist = TwistInstance.fromCache(
      TwistInstanceId.fromString(action.twistInstanceId),
    );
    final channelId = action.channelId;
    final channel = channelId != null
        ? Channel.findByChannel(
            TwistInstanceId.fromString(action.twistInstanceId),
            channelId,
          )
        : null;
    final channelType = channel?.parsedLinkTypes
        ?.where((c) => c.type == action.linkType)
        .firstOrNull;
    final twistType = twist?.parsedLinkTypes
        ?.where((c) => c.type == action.linkType)
        .firstOrNull;
    final statuses = (channelType?.statuses?.isNotEmpty ?? false)
        ? channelType!.statuses!
        : (twistType?.statuses ?? const <LinkStatus>[]);
    final currentStatusLabel =
        (channelType?.statuses ?? const <LinkStatus>[])
            .where((s) => s.status == action.status)
            .firstOrNull
            ?.label ??
        (twistType?.statuses ?? const <LinkStatus>[])
            .where((s) => s.status == action.status)
            .firstOrNull
            ?.label ??
        action.status;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: logo != null
                ? LogoImage(
                    url: logo,
                    size: 16,
                    fallback: Icon(
                      PlotIcon.link,
                      size: 12,
                      color: context.colour.muted,
                    ),
                  )
                : Icon(PlotIcon.link, size: 12, color: context.colour.muted),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: context.theme.typography.xs.copyWith(
                  color: context.colour.muted,
                ),
                children: [
                  TextSpan(text: action.title),
                  TextSpan(
                    text: '  ${action.subtitle}',
                    style: TextStyle(color: context.theme.plotColors.veryMuted),
                  ),
                ],
              ),
            ),
          ),
          if (statuses.isNotEmpty) ...[
            FButton(
              onPress: () => _pickCreateLinkStatus(action, statuses),
              variant: FButtonVariant.ghost,
              style: ghostSizedStyleDelta(
                context,
                textStyle: context.theme.typography.xs,
              ),
              mainAxisSize: MainAxisSize.min,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Text(currentStatusLabel),
                  Icon(
                    PlotIcon.verticalExpand,
                    size: context.theme.iconSizes.xs,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
          ],
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _removeAttachment(action),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Icon(
                FontAwesomeIcons.xmark,
                size: 12,
                color: context.colour.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCreateLinkStatus(
    CreateLinkUserAction action,
    List<LinkStatus> statuses,
  ) async {
    final result = await SelectModal.open<LinkStatus>(
      context,
      items: (_) async => [SelectGroup(title: null, items: statuses)],
      itemBuilder: (s, _) =>
          ListTile(body: Text(s.label), selected: s.status == action.status),
      selectedValue: statuses
          .where((s) => s.status == action.status)
          .firstOrNull,
      prompt: 'Select status',
    );
    if (!result.present || !mounted) return;
    final newStatus = result.value;
    final updatedAction = action.copyWith(status: newStatus.status);
    final updatedActions = _currentActions
        .map((a) => identical(a, action) ? updatedAction : a)
        .toList();
    _setCurrentActions(updatedActions);
  }

  void _removeAttachment(UserAction action) {
    final updatedActions = _currentActions.where((a) => a != action).toList();
    _setCurrentActions(updatedActions);
  }

  // -- Capability gating --

  /// True when "Add link" should be shown for [cfg]. Null config = private Plot
  /// note (always allowed); otherwise the link type must declare support.
  bool _canAddLink(LinkTypeConfig? cfg) => cfg == null || cfg.supportsLinks;

  /// True when "Attach file" should be shown for [cfg]. Null config = private
  /// Plot note (always allowed); otherwise the link type must declare support.
  bool _canAttachFile(LinkTypeConfig? cfg) =>
      cfg == null || cfg.supportsFileAttachments;

  /// The LinkTypeConfig governing the note currently being edited: the selected
  /// create-action's type in new-thread mode, else the thread's primary link.
  /// Null means a private Plot note (both actions allowed).
  LinkTypeConfig? _activeLinkTypeConfig(BuildContext context) {
    if (widget.isNewThreadMode) {
      return linkTypeConfigForCreateAction(
        widget.draft.actions?.whereType<CreateLinkUserAction>().firstOrNull,
      );
    }
    return context.read<ThreadBloc>().state.primaryLinkTypeConfig;
  }

  // -- Bottom bars --

  Widget _buildNoteBottomBar(BuildContext context) {
    return BlocBuilder<ThreadBloc, ThreadState>(
      buildWhen: (prev, curr) =>
          prev.editingNote != curr.editingNote || prev.draft != curr.draft,
      builder: (context, activityState) {
        final isCurrentlyEditing = activityState.editingNote != null;
        final threadState = context.read<ThreadBloc>().state;
        final priorityId = threadState.thread.priority.id.toString();

        void applyActions(List<UserAction> actions) =>
            _setCurrentActions(actions);

        return Row(
          children: [
            IgnorePointer(
              ignoring: _saving,
              child: Opacity(
                opacity: _saving ? 0.6 : 1.0,
                child: Row(
                  children: [
                    // Link button — only when the source can carry a link.
                    if (_canAddLink(threadState.primaryLinkTypeConfig))
                      Button.icon(
                        AddLink(
                          currentActions: _currentActions,
                          onActionsChanged: applyActions,
                          onNavigateToThread: widget.onNavigateToThread,
                        ),
                      ),
                    if (_canAttachFile(threadState.primaryLinkTypeConfig))
                      Button.icon(
                        AttachFile(
                          priorityId: priorityId,
                          currentLinks: _currentActions,
                          onLinksChanged: applyActions,
                        ),
                      ),
                    if (isMobilePlatform())
                      Button.icon(
                        TakePhoto(
                          priorityId: priorityId,
                          currentLinks: _currentActions,
                          onLinksChanged: applyActions,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            // Right side: Save button (always visible). Label adapts to the
            // active top-bar pill — Save, Save task, Send, or a connector
            // verb like "Comment" / "Reply" from the LinkTypeConfig.
            Button.icon(
              isCurrentlyEditing
                  ? CommandWrapper(
                      AddNote(
                        Future.value(widget.draft),
                        linkType: threadState.primaryLinkTypeConfig,
                      ),
                      title: 'Save changes',
                      icon: Value(PlotIcon.save),
                      run: (action, context) async {
                        _editorKey.currentState?.submit(false);
                        return const CommandDone();
                      },
                    )
                  : CommandWrapper(
                      AddNote(
                        Future.value(widget.draft),
                        linkType: threadState.primaryLinkTypeConfig,
                      ),
                      title: _sendLabelForState(activityState),
                      run: (action, context) async {
                        _editorKey.currentState?.submit(false);
                        return const CommandDone();
                      },
                    ),
              style: ButtonStyle.primary,
              loading: _saving,
              enabled: !_saving && (!_isEmpty || _currentActions.isNotEmpty),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNewThreadBottomBar() {
    final thread = widget.thread!;
    final draftNote = widget.draft;
    final linkType = linkTypeConfigForCreateAction(
      draftNote.actions?.whereType<CreateLinkUserAction>().firstOrNull,
    );
    return Row(
      children: [
        IgnorePointer(
          ignoring: _saving,
          child: Opacity(
            opacity: _saving ? 0.6 : 1.0,
            child: Row(
              children: [
                // Link button — only when the target source can carry a link.
                if (_canAddLink(linkType))
                  Button.icon(
                    AddLink(
                      currentActions: draftNote.actions ?? const [],
                      onActionsChanged: (actions) {
                        widget.onDraftChanged!(
                          thread,
                          note: draftNote.copyWith(actions: actions),
                        );
                      },
                      onNavigateToThread: widget.onNavigateToThread,
                    ),
                  ),
                if (_canAttachFile(linkType))
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
            AddThread(
              Future.value(thread),
              linkType: linkTypeConfigForCreateAction(
                draftNote.actions
                    ?.whereType<CreateLinkUserAction>()
                    .firstOrNull,
              ),
            ),
            title: widget.sendLabel,
            run: (action, context) async {
              _editorKey.currentState?.submit(false);
              return const CommandDone();
            },
          ),
          style: ButtonStyle.primary,
          loading: _saving,
          // Body-less submit is allowed only when there's an external link
          // (handled below by AddThreadWithLink). Other action types
          // (file attachments, connector create-actions) still need a body
          // because they piggyback on the saved Note.
          enabled:
              !_saving &&
              (!_isEmpty ||
                  (widget.draft.actions
                          ?.whereType<ExternalUserAction>()
                          .isNotEmpty ??
                      false)),
        ),
      ],
    );
  }

  // -- Keyboard shortcuts --

  /// Builds keyboard shortcut bindings for note-level actions. These fire
  /// from anywhere inside the NoteEditor (editor + toolbar). Uses mode
  /// (new-thread vs note) to invoke the same logic the toolbar buttons use.
  Map<ShortcutActivator, VoidCallback> _buildNoteShortcuts(
    BuildContext context,
  ) {
    final bindings = <ShortcutActivator, VoidCallback>{};

    // ⌘T — toggle self task
    bindings[platformSingleActivator(LogicalKeyboardKey.keyT)] = () =>
        _shortcutToggleSelfTask(context);

    // ⌘⇧L — add link
    bindings[platformSingleActivator(
      LogicalKeyboardKey.keyL,
      shift: true,
    )] = () =>
        _shortcutAddLink(context);

    return bindings;
  }

  void _shortcutToggleSelfTask(BuildContext context) {
    if (_saving) return;
    if (widget.isNewThreadMode) {
      if (widget.viewerMode) return;
      final updatedNote = widget.draft.toggleTag(Tag.todo, Base.actorId);
      widget.onDraftChanged?.call(widget.thread!, note: updatedNote);
    } else {
      context.run(ToggleSelfTask(widget.draft));
    }
  }

  void _shortcutAddLink(BuildContext context) {
    if (_saving) return;
    // Respect the same per-link-type gating the toolbar button uses.
    if (!_canAddLink(_activeLinkTypeConfig(context))) return;
    context.run(
      AddLink(
        currentActions: _currentActions,
        onActionsChanged: _setCurrentActions,
        onNavigateToThread: widget.onNavigateToThread,
      ),
    );
  }

  // -- Submit handlers --

  Future<void> _onNoteSubmitted(String body, {bool alt = false}) async {
    // Block subsequent _saveDraft calls and wait out any already in flight,
    // so the publish writes can't be reordered with a draft write.
    _finalized = true;
    await _pendingDraftSave;
    if (!mounted) return;

    // Note mode has no onChange auto-save (onChange is wired only in
    // new-thread mode), so _lastSavedContent reflects only what was
    // persisted to the draft — usually '' — not what the user actually
    // typed. didUpdateWidget's reset-skip optimization treats
    // _lastSavedContent as a proxy for the editor's current content;
    // without bumping it here, the empty post-add() draft and the stale
    // empty _lastSavedContent compare equal, the SuperEditor reset is
    // skipped, and the just-submitted text stays on screen.
    _lastSavedContent = body;

    final activityBloc = context.read<ThreadBloc>();
    final editingNote = activityBloc.state.editingNote;

    if (editingNote != null) {
      // Editing mode: update the existing note
      setState(() {
        _saving = true;
      });
      try {
        final updatedNote = editingNote.copyWith(
          content: body,
          actions: _editingActions ?? editingNote.actions,
        );
        await activityBloc.updateNote(updatedNote);
        if (mounted) {
          setState(() {
            _editingActions = null;
          });
        }
        // Reset editor to draft content
        _editorKey.currentState?.reset(widget.draft.content ?? '');
      } finally {
        if (mounted) {
          setState(() {
            _saving = false;
            // Re-enable _saveDraft for the standalone draft now that the
            // edited note has been published.
            _finalized = false;
          });
        }
      }
    } else {
      // Normal mode: add a new note
      final note = _finalizeNoteDraft(body, alt: alt);
      if (!context.mounted) return;
      final threadCfg = context.read<ThreadBloc>().state.primaryLinkTypeConfig;
      setState(() {
        _saving = true;
      });
      try {
        await context.run(AddNote(note, linkType: threadCfg));
      } finally {
        if (mounted) {
          setState(() {
            _saving = false;
            // Re-enable _saveDraft for the fresh draft that ThreadBloc.add()
            // emitted in place of the just-published one. Without this,
            // future blur/deactivate writes are silently dropped and the
            // new draft never persists.
            _finalized = false;
          });
        }
      }
    }
  }

  Future<void> _onNewThreadSubmitted(String body, {bool alt = false}) async {
    // Run the caller's pre-submit validator (e.g. DM-type recipient gate).
    final validationError = widget.submitValidator?.call();
    if (validationError != null) {
      if (mounted) {
        context.showToast(message: validationError, isError: true);
      }
      return;
    }

    // Block subsequent _saveDraft calls and wait out any already in flight,
    // so the publish writes can't be reordered with a draft write.
    _finalized = true;
    await _pendingDraftSave;
    if (!mounted) return;

    // Empty body + a link → create a thread *about* the link: title and
    // favicon come from the link, no Note is saved, the link is stored as a
    // thread-level LinkRow (matches how thread.dart renders link rows).
    if (body.trim().isEmpty) {
      final firstExternal = widget.draft.actions
          ?.whereType<ExternalUserAction>()
          .firstOrNull;
      if (firstExternal != null) {
        setState(() => _saving = true);
        widget.onSubmitted?.call();
        try {
          await context.run(
            AddThreadWithLink(
              linkUrl: firstExternal.url,
              linkTitle: firstExternal.title,
              linkFavicon: firstExternal.favicon,
            ),
          );
        } finally {
          if (mounted) setState(() => _saving = false);
        }
        return;
      }
    }

    final data = await finalizeThreadDraft(
      body,
      twists: context.read<PriorityBloc>().state.twists,
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

  /// Returns the twist ActorIds to mention on submit. Source connectors are
  /// included only when [includeConnectors] is true. Non-source twists are
  /// included when they authored a note/link on the thread (with
  /// `defaultMentionCreated`) or were @-mentioned (with
  /// `defaultMentionMentioned`) — i.e. the ambient defaults that previously
  /// seeded `_disabledTwists`.
  List<ActorId> _getActiveTwistMentions({required bool includeConnectors}) {
    if (widget.isNewThreadMode) return const [];
    final s = context.read<ThreadBloc>().state;
    return s.threadTwists
        .where((t) {
          if (t.isSource) {
            return includeConnectors &&
                t.userConnected &&
                t.defaultMentionCreated;
          }
          final isAuthor =
              s.notes.any((n) => n.authorId.toUuid() == t.id) ||
              s.links.any((l) => l.createdBy == t.id);
          return (isAuthor && t.defaultMentionCreated) ||
              t.defaultMentionMentioned;
        })
        .map((t) => ActorId.fromUuid(t.id))
        .toList();
  }

  Future<Note> _finalizeNoteDraft(String body, {bool alt = false}) async {
    _finalized = true;

    // Get replyTo from ThreadBloc state
    final activityBloc = context.read<ThreadBloc>();
    final replyTo = activityBloc.state.replyTo;
    final thread = activityBloc.state.thread;

    // When replying to a private note, auto-private the reply and carry over
    // the original note's author + mentions so they can see it.
    final replyRestricted = replyTo != null && replyTo.isPrivate;
    final replyAccessContacts = replyRestricted
        ? <ActorId>{replyTo.authorId, ...?replyTo.accessContacts}.toList()
        : <ActorId>[];

    // A note is private when replying to a private note, in viewer mode, or
    // when the user toggled the private tag. Private notes are kept among the
    // selected people and are never sent to the thread's connector.
    final isPrivateNote =
        widget.viewerMode || replyRestricted || widget.draft.isPrivate;

    // Merge active twist mentions into the note. Private notes don't trigger
    // any twist — neither source connectors nor non-source twists (e.g. Plot
    // AI) — since "Private note" semantically means the user wrote it for
    // themselves and doesn't want a response.
    final activeTwistMentions = isPrivateNote
        ? const <ActorId>[]
        : _getActiveTwistMentions(includeConnectors: true);
    final allAddMentions = [...activeTwistMentions, ...replyAccessContacts];

    // Default share targets for read-only-thread viewers: every contact on
    // the thread plus members of non-announce groups. The viewer's own
    // contacts are added implicitly server-side; announce-group members
    // (other read-only viewers) are intentionally excluded so notes don't
    // broadcast back through the announce channel.
    final readOnlyThreadShare = widget.viewerMode && thread.isReadOnly
        ? _readOnlyDefaultShareTargets(thread)
        : <ActorId>[];

    final Value<List<ActorId>?> accessContactsValue =
        (widget.viewerMode || replyRestricted)
        ? Value(
            <ActorId>{...replyAccessContacts, ...readOnlyThreadShare}.toList(),
          )
        : const Value.absent();

    Note note = widget.draft.copyWith(
      content: body.isEmpty ? null : body,
      draft: false,
      reNoteId: replyTo?.id,
      addMentions: allAddMentions.isNotEmpty ? allAddMentions : null,
      accessContacts: accessContactsValue,
    );

    // If Cmd-Enter was pressed, assign the note to current user
    if (alt && !note.isAssignedTo(Base.actorId)) {
      note = note.assignTo(Base.actorId);
    }

    return note;
  }

  /// Default share-target list for a read-only viewer's note: every contact
  /// listed on the thread plus members of any non-announce group on the
  /// thread. Announce-group members are excluded so a private note from a
  /// read-only viewer is visible to the people who can write to the thread,
  /// but not to other read-only viewers.
  List<ActorId> _readOnlyDefaultShareTargets(Thread thread) {
    final result = <ActorId>{};
    // Exclude dropped contacts — they retain visibility into past notes but
    // shouldn't be added to the access_contacts of a new note.
    for (final contactId in thread.activeContacts) {
      result.add(ActorId.fromUuid(contactId));
    }
    for (final groupId in thread.groups) {
      final group = Group.fromCache(groupId);
      if (group == null || group.type == 'announce') continue;
      for (final memberId in group.memberContactIds ?? const <Uuid>[]) {
        result.add(ActorId.fromUuid(memberId));
      }
    }
    return result.toList();
  }

  /// Kept public for note mode compatibility (ThreadPage calls this).
  Future<Note> finalizeDraft(String body, {bool alt = false}) =>
      _finalizeNoteDraft(body, alt: alt);

  Future<ThreadWithNote> finalizeThreadDraft(
    String body, {
    required List<TwistInstance> twists,
    required bool alt,
  }) async {
    _finalized = true;

    // Store a normalised single-line preview from body content for
    // client-side display and server-side AI title generation. Title is
    // left null when the user hasn't set one — the client derives
    // displayTitle from preview, and the server generates an AI title on
    // sync. If the user set a title via the title modal, preserve it and
    // use the body as the preview.
    final previewContent = Thread.createPreviewFromMarkdown(body);
    final existingTitle = widget.thread!.title;
    log.info('Finalizing draft with preview-based title');

    // Apply "Do Now" scheduling only if Cmd-Enter (alt) was used
    final shouldSchedule = alt;
    final hasDateTime = widget.thread!.at != null;

    // Mirror the server's upsert_thread merge: if no linked contact of the
    // author is already in thread.contacts, append their primary contact so
    // the local row matches what the server will store. Without this the
    // author's freshly-finalized thread looks read-only locally (isReadOnly
    // sees no self in contacts and no group, hiding the header Edit/Share
    // buttons until sync round-trips the server-merged contact list back).
    final selfActorIds = Actor.getCurrentUserActorIds()
        .map((a) => a.toUuid())
        .toSet();
    final currentContacts = widget.thread!.contacts;
    final selfPrimary = Base.actorIdOrNull?.toUuid();
    final List<Uuid>? mergedContacts =
        (selfPrimary != null && !currentContacts.any(selfActorIds.contains))
        ? [...currentContacts, selfPrimary]
        : null;

    // Create Thread — title null signals server to generate AI title
    final thread = widget.thread!.copyWith(
      title: Value(existingTitle),
      preview: Value(previewContent),
      draft: false,
      contacts: mergedContacts != null
          ? Value(mergedContacts)
          : const Value.absent(),
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

    // Cmd-Enter (alt) adds the thread to agenda (Do Now scheduling).
    // Note assignment is never automatic — users toggle "Add task" in the
    // editor when they want a note assigned to themselves.
    return ThreadWithNote(thread: thread, note: note);
  }
}
