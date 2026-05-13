import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/store/store.dart';

import 'package:plot/state/thread.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/image_utils.dart';
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
    this.twists,
    this.actors,
    this.onDraftChanged,
    this.showScheduleActions = true,
    this.hint,
    this.additionalMentions,
    this.onSubmitted,
    this.viewerMode = false,
    // Twist selection (new-thread mode)
    this.selectedTwist,
    this.onTwistSelected,
    // Link/navigation callbacks
    this.onNavigateToThread,
    this.autofocus,
    super.key,
  });

  final Note draft;
  final bool flushToBottom;

  /// When non-null, the editor operates in new-thread mode.
  final Thread? thread;
  final List<TwistInstance>? twists;
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

  /// When true, hides all toolbar controls for viewer-created content in
  /// readonly priorities. Notes are auto-private.
  final bool viewerMode;

  /// Currently selected twist (new-thread mode). Button shows selected state.
  final TwistInstance? selectedTwist;

  /// Called when user selects a twist from the picker modal.
  final ValueChanged<TwistInstance>? onTwistSelected;

  /// Called when user selects an existing thread from the link modal.
  final void Function(Thread thread)? onNavigateToThread;

  /// Override the editor's default autofocus behavior. When null, the editor
  /// autofocuses in new-thread mode or when a physical keyboard is present.
  final bool? autofocus;

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
  // Tracks the most recent in-flight _saveDraft. Submit handlers await this
  // before publishing so the publish can't race with a keystroke-triggered
  // save that already passed the _finalized check.
  Future<void>? _pendingDraftSave;

  /// Twist IDs toggled OFF by the user for the current note.
  final Set<TwistInstanceId> _disabledTwists = {};

  void _resetDisabledTwists() {
    _disabledTwists.clear();
    if (widget.isNewThreadMode) return;
    final threadState = context.read<ThreadBloc>().state;
    for (final twist in threadState.threadTwists) {
      // Unconnected sources are never mentionable
      if (twist.isSource && !twist.userConnected) {
        _disabledTwists.add(twist.id);
        continue;
      }
      // Connectors that don't handle replies are never mentionable
      if (twist.isSource && !twist.defaultMentionCreated) continue;
      // Sources with defaultMentionCreated always default ON —
      // they appear in threadTwists because they created this thread
      if (twist.isSource && twist.defaultMentionCreated) continue;
      final isAuthor =
          threadState.notes.any((n) => n.authorId.toUuid() == twist.id) ||
          threadState.links.any((l) => l.createdBy == twist.id);
      final shouldDefault =
          (isAuthor && twist.defaultMentionCreated) ||
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
    _resetDisabledTwists();
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
    _updateActions([
      ...(widget.draft.actions ?? const <UserAction>[]),
      placeholder,
    ]);

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

      final actions = widget.draft.actions ?? const <UserAction>[];
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
      _updateActions(updated);
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
    final actions = widget.draft.actions ?? const <UserAction>[];
    final filtered = actions
        .where((a) => !(a is FileUserAction && a.fileId == pendingFileId))
        .toList();
    if (filtered.length == actions.length) return;
    _updateActions(filtered);
  }

  /// Handle a URL pasted into an otherwise empty editor: attach it as an
  /// `ExternalUserAction` (the same shape the link command produces) and
  /// asynchronously resolve title and favicon to update the placeholder.
  Future<void> _handleUrlPasteWhenEmpty(String url) async {
    final placeholder = ExternalUserAction(title: url, url: url);
    final currentActions = widget.draft.actions ?? const <UserAction>[];
    _updateActions([...currentActions, placeholder]);

    final metadata = await fetchUrlMetadata(url);
    if (!mounted) return;
    if (metadata.title == null && metadata.favicon == null) return;

    final actions = widget.draft.actions ?? const <UserAction>[];
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
    _updateActions(updated);
  }

  void _updateActions(List<UserAction> actions) {
    final updatedDraft = widget.draft.copyWith(actions: actions);
    if (widget.isNewThreadMode) {
      widget.onDraftChanged!(widget.thread!, note: updatedDraft);
    } else {
      context.read<ThreadBloc>().updateDraft(updatedDraft);
    }
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
      return _buildEditorArea(
        twists: widget.twists!,
        actors: widget.actors ?? const [],
      );
    }

    // Note mode: wrap with BlocListener (editing) and BlocBuilder (twists/actors)
    return BlocListener<ThreadBloc, ThreadState>(
      listenWhen: (prev, curr) =>
          prev.editingNote != curr.editingNote || prev.replyTo != curr.replyTo,
      listener: (context, activityState) {
        if (activityState.editingNote != null) {
          // Load editing note content into editor
          _editorKey.currentState?.reset(
            activityState.editingNote!.content ?? '',
          );
          focus();
        } else if (activityState.replyTo != null) {
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
    required List<TwistInstance> twists,
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
          autofocus:
              widget.autofocus ??
              (widget.isNewThreadMode || hasPhysicalKeyboard()),
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
          onImagePasted: (imageBytes) => _handleImagePaste(imageBytes),
          onUrlPastedWhenEmpty: (url) => _handleUrlPasteWhenEmpty(url),
        );

        return CallbackShortcuts(
          bindings: _buildNoteShortcuts(context),
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
              // Reply, editing, and twist indicators (note mode only)
              if (!widget.isNewThreadMode) _buildNoteIndicators(context),
              // Attachment and link rows (both modes)
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
                              background:
                                  context.theme.plotColors.editableBackground,
                              child: editor,
                            ),
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
          prev.editingNote != curr.editingNote,
      builder: (context, state) {
        final indicators = <Widget>[
          if (state.replyTo != null)
            _buildReplyIndicatorContent(context, state.replyTo!),
          if (state.editingNote != null)
            _buildEditingIndicatorContent(context, state.editingNote!),
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

  // -- Attachment rows (both modes) --

  /// Renders attached files and links as compact rows with an X to remove.
  Widget _buildAttachmentRows() {
    final actions = widget.draft.actions;
    if (actions == null || actions.isEmpty) return const SizedBox.shrink();

    final attachments = actions
        .where(
          (a) =>
              a.type == UserActionType.file ||
              a.type == UserActionType.external ||
              a.type == UserActionType.createLink,
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
    final channel = Channel.findByChannel(
      TwistInstanceId.fromString(action.twistInstanceId),
      action.channelId,
    );
    final channelType = channel?.parsedLinkTypes
        ?.where((c) => c.type == action.linkType)
        .firstOrNull;
    final twistType = twist?.parsedLinkTypes
        ?.where((c) => c.type == action.linkType)
        .firstOrNull;
    final statuses = (channelType?.statuses?.isNotEmpty ?? false)
        ? channelType!.statuses!
        : (twistType?.statuses ?? const <LinkStatus>[]);
    final currentStatusLabel = (channelType?.statuses ?? const <LinkStatus>[])
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
                    style: TextStyle(
                      color: context.theme.plotColors.veryMuted,
                    ),
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
      itemBuilder: (s, _) => ListTile(
        body: Text(s.label),
        selected: s.status == action.status,
      ),
      selectedValue: statuses
          .where((s) => s.status == action.status)
          .firstOrNull,
      prompt: 'Select status',
    );
    if (!result.present || !mounted) return;
    final newStatus = result.value;
    final updatedAction = action.copyWith(status: newStatus.status);
    final currentActions = widget.draft.actions ?? const [];
    final updatedActions = currentActions
        .map((a) => identical(a, action) ? updatedAction : a)
        .toList();
    if (widget.isNewThreadMode) {
      widget.onDraftChanged!(
        widget.thread!,
        note: widget.draft.copyWith(actions: updatedActions),
      );
    } else {
      context
          .read<ThreadBloc>()
          .updateDraft(widget.draft.copyWith(actions: updatedActions));
    }
  }

  void _removeAttachment(UserAction action) {
    final currentActions = widget.draft.actions ?? const [];
    final updatedActions = currentActions.where((a) => a != action).toList();

    if (widget.isNewThreadMode) {
      widget.onDraftChanged!(
        widget.thread!,
        note: widget.draft.copyWith(actions: updatedActions),
      );
    } else {
      final updatedDraft = widget.draft.copyWith(actions: updatedActions);
      context.read<ThreadBloc>().updateDraft(updatedDraft);
    }
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
        return Row(
          children: [
            if (!isCurrentlyEditing)
              IgnorePointer(
                ignoring: _saving,
                child: Opacity(
                  opacity: _saving ? 0.6 : 1.0,
                  child: Row(
                    children: [
                      // Task toggle
                      Button.icon(
                        ToggleSelfTask(widget.draft),
                        selected: widget.draft.isAssignedTo(Base.actorId),
                      ),
                      // Assign
                      Button.icon(
                        PickNoteAssignee(widget.draft),
                        selected: widget.draft.assignees.any(
                          (id) => !id.isCurrentUser,
                        ),
                      ),
                      // Private toggle (only for threads with other contacts)
                      if (threadState.thread.contacts.length > 1 &&
                          (!widget.draft.isPrivate ||
                              widget.draft.authorId.isCurrentUser))
                        Button.icon(
                          ToggleNoteTag(
                            widget.draft,
                            Tag.private,
                            Base.actorId,
                          ),
                          selected: widget.draft.isPrivate,
                        ),
                      // Link button
                      Button.icon(
                        AddLink(
                          currentActions: widget.draft.actions ?? const [],
                          onActionsChanged: (actions) {
                            final updatedDraft = widget.draft.copyWith(
                              actions: actions,
                            );
                            context.read<ThreadBloc>().updateDraft(
                              updatedDraft,
                            );
                          },
                          onNavigateToThread: widget.onNavigateToThread,
                        ),
                      ),
                      Button.icon(
                        AttachFile(
                          priorityId: priorityId,
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
                      if (isMobilePlatform())
                        Button.icon(
                          TakePhoto(
                            priorityId: priorityId,
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
                      // Twist button (only when thread has twists)
                      if (threadState.threadTwists.isNotEmpty)
                        _buildTwistButton(context),
                      // Connector button (autoReply connectors on thread)
                      if (threadState.threadTwists.isNotEmpty)
                        _buildConnectorButton(context),
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
                  (!_isEmpty || (widget.draft.actions?.isNotEmpty ?? false)),
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
                if (!widget.viewerMode && !thread.priority.isViewer) ...[
                  // Task toggle — use CommandWrapper to update draft instead of saving
                  Button.icon(
                    CommandWrapper(
                      ToggleSelfTask(draftNote),
                      run: (action, ctx) async {
                        final updatedNote = draftNote.toggleTag(
                          Tag.todo,
                          Base.actorId,
                        );
                        widget.onDraftChanged!(thread, note: updatedNote);
                        return const CommandDone();
                      },
                    ),
                    selected: draftNote.isAssignedTo(Base.actorId),
                  ),
                ],
                if (!widget.viewerMode && !thread.priority.isViewer)
                  Button.icon(
                    PickDraftNoteAssignee(
                      note: draftNote,
                      thread: thread,
                      priorityId: thread.priority.id,
                      onUpdate: (note, {Thread? thread}) =>
                          widget.onDraftChanged!(
                            thread ?? widget.thread!,
                            note: note,
                          ),
                    ),
                    selected: draftNote.assignees.any(
                      (id) => !id.isCurrentUser,
                    ),
                  ),
                // Link button
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
                // Twist button (when twists are available)
                if (!widget.viewerMode && (widget.twists?.isNotEmpty ?? false))
                  _buildNewThreadTwistButton(),
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

  // -- Twist buttons --

  /// Twist button for note mode (ThreadPage). Opens a modal showing
  /// thread twists with toggle state. Source connectors are handled by
  /// the separate connector (plug) button and excluded here.
  Widget _buildTwistButton(BuildContext context) {
    final threadState = context.read<ThreadBloc>().state;
    final mentionableTwists = threadState.threadTwists
        .where((t) => !t.isSource)
        .toList();
    if (mentionableTwists.isEmpty) return const SizedBox.shrink();

    final anyEnabled = mentionableTwists.any(
      (t) => !_disabledTwists.contains(t.id),
    );

    return Button.icon(
      CommandWrapper(
        PickTwist(),
        run: (action, ctx) async {
          // Single twist: click toggles directly without opening a modal.
          if (mentionableTwists.length == 1) {
            setState(() {
              final id = mentionableTwists.first.id;
              if (_disabledTwists.contains(id)) {
                _disabledTwists.remove(id);
              } else {
                _disabledTwists.add(id);
              }
            });
            return const CommandDone();
          }
          await _openTwistToggleModal(ctx, mentionableTwists);
          return const CommandDone();
        },
      ),
      selected: anyEnabled,
    );
  }

  /// Plug button for autoReply connectors on the thread. Toggles all
  /// connectors on or off together. Hidden when no autoReply connectors
  /// are present.
  Widget _buildConnectorButton(BuildContext context) {
    final threadState = context.read<ThreadBloc>().state;
    final connectors = threadState.threadTwists
        .where((t) => t.isSource && t.defaultMentionCreated)
        .toList();
    if (connectors.isEmpty) return const SizedBox.shrink();

    final anyEnabled = connectors.any(
      (c) => !_disabledTwists.contains(c.id),
    );
    final names = connectors.map((c) => c.name).join(', ');
    return Button.icon(
      CommandWrapper(
        PickTwist(),
        title: 'Send to $names',
        icon: Value(PlotIcon.connection),
        run: (action, ctx) async {
          setState(() {
            if (anyEnabled) {
              // Disable all
              for (final c in connectors) {
                _disabledTwists.add(c.id);
              }
            } else {
              // Enable all
              for (final c in connectors) {
                _disabledTwists.remove(c.id);
              }
            }
          });
          return const CommandDone();
        },
      ),
      selected: anyEnabled,
    );
  }

  Future<void> _openTwistToggleModal(
    BuildContext context,
    List<TwistInstance> twists,
  ) async {
    final result = await SelectModal.open<TwistInstance>(
      context,
      items: (_) async => [SelectGroup(title: null, items: twists)],
      itemBuilder: (twist, _) {
        final disabled = _disabledTwists.contains(twist.id);
        final isDark = context.colour.brightness == Brightness.dark;
        final logoUrl = isDark && twist.logoUrlDark != null
            ? twist.logoUrlDark
            : twist.logoUrl;
        return ListTile(
          selected: !disabled,
          body: Row(
            spacing: 8,
            children: [
              if (logoUrl != null)
                LogoImage(url: logoUrl, size: 14)
              else
                Icon(PlotIcon.twist, size: 14),
              Text(twist.displayName(allInstances: twists, teamName: null)),
            ],
          ),
        );
      },
      prompt: 'Select twists',
    );

    if (!context.mounted || !result.present) return;
    setState(() {
      final twist = result.value;
      if (_disabledTwists.contains(twist.id)) {
        _disabledTwists.remove(twist.id);
      } else {
        _disabledTwists.add(twist.id);
      }
    });
  }

  /// Twist button for new-thread mode. Opens a single-select modal.
  Widget _buildNewThreadTwistButton() {
    final hasTwist = widget.selectedTwist != null;
    return Button.icon(
      CommandWrapper(
        PickTwist(),
        run: (action, ctx) async {
          await _openNewThreadTwistPicker(ctx);
          return const CommandDone();
        },
      ),
      selected: hasTwist,
    );
  }

  Future<void> _openNewThreadTwistPicker(BuildContext context) async {
    final twists = (widget.twists ?? const <TwistInstance>[])
        .where((t) => !t.isSource)
        .toList();
    if (twists.isEmpty) return;

    final result = await SelectModal.open<TwistInstance>(
      context,
      items: (_) async => [SelectGroup(title: null, items: twists)],
      itemBuilder: (twist, _) {
        final isDark = context.colour.brightness == Brightness.dark;
        final logoUrl = isDark && twist.logoUrlDark != null
            ? twist.logoUrlDark
            : twist.logoUrl;
        return ListTile(
          body: Row(
            spacing: 8,
            children: [
              if (logoUrl != null)
                LogoImage(url: logoUrl, size: 14)
              else
                Icon(PlotIcon.twist, size: 14),
              Text(twist.displayName(allInstances: twists, teamName: null)),
            ],
          ),
        );
      },
      selectedValue: widget.selectedTwist,
      prompt: 'Select twist',
    );

    if (!context.mounted || !result.present) return;
    widget.onTwistSelected?.call(result.value);
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
    bindings[platformSingleActivator(LogicalKeyboardKey.keyT)] =
        () => _shortcutToggleSelfTask(context);

    // ⌘⇧T — assign
    bindings[platformSingleActivator(LogicalKeyboardKey.keyT, shift: true)] =
        () => _shortcutAssign(context);

    // ⌘⇧L — add link
    bindings[platformSingleActivator(LogicalKeyboardKey.keyL, shift: true)] =
        () => _shortcutAddLink(context);

    // ⌘⇧M — select twist
    bindings[platformSingleActivator(LogicalKeyboardKey.keyM, shift: true)] =
        () => _shortcutSelectTwist(context);

    return bindings;
  }

  void _shortcutToggleSelfTask(BuildContext context) {
    if (_saving) return;
    if (widget.isNewThreadMode) {
      if (widget.viewerMode || widget.thread!.priority.isViewer) return;
      final updatedNote = widget.draft.toggleTag(Tag.todo, Base.actorId);
      widget.onDraftChanged?.call(widget.thread!, note: updatedNote);
    } else {
      context.run(ToggleSelfTask(widget.draft));
    }
  }

  void _shortcutAssign(BuildContext context) {
    if (_saving) return;
    if (widget.isNewThreadMode) {
      if (widget.viewerMode || widget.thread!.priority.isViewer) return;
      context.run(
        PickDraftNoteAssignee(
          note: widget.draft,
          thread: widget.thread!,
          priorityId: widget.thread!.priority.id,
          onUpdate: (note, {Thread? thread}) =>
              widget.onDraftChanged?.call(
                thread ?? widget.thread!,
                note: note,
              ) ??
              Future.value(),
        ),
      );
    } else {
      context.run(PickNoteAssignee(widget.draft));
    }
  }

  void _shortcutAddLink(BuildContext context) {
    if (_saving) return;
    final currentActions = widget.draft.actions ?? const <UserAction>[];
    void onActionsChanged(List<UserAction> actions) {
      final updatedDraft = widget.draft.copyWith(actions: actions);
      if (widget.isNewThreadMode) {
        widget.onDraftChanged?.call(widget.thread!, note: updatedDraft);
      } else {
        context.read<ThreadBloc>().updateDraft(updatedDraft);
      }
    }

    context.run(
      AddLink(
        currentActions: currentActions,
        onActionsChanged: onActionsChanged,
        onNavigateToThread: widget.onNavigateToThread,
      ),
    );
  }

  void _shortcutSelectTwist(BuildContext context) {
    if (_saving) return;
    if (widget.isNewThreadMode) {
      if (widget.viewerMode || (widget.twists?.isEmpty ?? true)) return;
      _openNewThreadTwistPicker(context);
    } else {
      final threadState = context.read<ThreadBloc>().state;
      final mentionableTwists = threadState.threadTwists
          .where((t) => !t.isSource)
          .toList();
      if (mentionableTwists.isEmpty) return;
      if (mentionableTwists.length == 1) {
        setState(() {
          final id = mentionableTwists.first.id;
          if (_disabledTwists.contains(id)) {
            _disabledTwists.remove(id);
          } else {
            _disabledTwists.add(id);
          }
        });
        return;
      }
      _openTwistToggleModal(context, mentionableTwists);
    }
  }

  // -- Submit handlers --

  Future<void> _onNoteSubmitted(String body, {bool alt = false}) async {
    // Block subsequent _saveDraft calls and wait out any already in flight,
    // so the publish writes can't be reordered with a draft write.
    _finalized = true;
    await _pendingDraftSave;
    if (!mounted) return;

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
    final thread = activityBloc.state.thread;

    // When replying to a private note, auto-private the reply and carry over
    // the original note's author + mentions so they can see it.
    final replyRestricted = replyTo != null && replyTo.isPrivate;
    final replyAccessContacts = replyRestricted
        ? <ActorId>{replyTo.authorId, ...?replyTo.accessContacts}.toList()
        : <ActorId>[];

    // Merge active twist mentions into the note
    final activeTwistMentions = _getActiveTwistMentions();
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
            ? Value(<ActorId>{
                ...replyAccessContacts,
                ...readOnlyThreadShare,
              }.toList())
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
    for (final contactId in thread.contacts) {
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

    // Store generous preview from body content for client-side display
    // and server-side AI title generation. Title is left null when the user
    // hasn't set one — the client derives displayTitle from preview, and the
    // server generates an AI title on sync. If the user set a title via the
    // title modal, preserve it and use the body as the preview.
    final previewContent = body.trim().isEmpty ? null : body.trim();
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
