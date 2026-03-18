import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:flutter_debouncer/flutter_debouncer.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart' hide Priority;
import 'package:plot/store/store.dart' as store show Priority;

import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/settings.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/command/command.dart';
import 'package:plot/command/page_link.dart';
import 'package:plot/util/platform.dart';
import 'package:plot/util/url_title.dart';
import 'sliver.dart';
import 'editor_mention_plugin.dart';
import 'editor_mention_detector.dart';
import 'editor_mention_popover.dart';
import 'editor_link_detector.dart';
import 'editor_link_toolbar.dart';
import 'editor_link_modal.dart';
import 'task_component.dart';
import 'logging.dart';

/// Information about a mention extracted from markdown
class _MentionInfo {
  const _MentionInfo({required this.name, required this.actorId});

  final String name;
  final String actorId;
}

/// Extract mention info from markdown before preprocessing
List<_MentionInfo> _extractMentions(String markdown) {
  final mentions = <_MentionInfo>[];
  final mentionPattern = RegExp(
    r'\[([^\]]+)\]\(#@([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)',
  );

  for (final match in mentionPattern.allMatches(markdown)) {
    mentions.add(
      _MentionInfo(name: match.group(1) ?? '', actorId: match.group(2) ?? ''),
    );
  }

  return mentions;
}

/// Preprocess markdown to convert mention formats to plain names for display
String _preprocessMarkdown(String markdown) {
  // Convert [Name](#@UUID) format to just Name (no @ prefix)
  String processed = markdown.replaceAllMapped(
    RegExp(
      r'\[([^\]]+)\]\(#@[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\)',
    ),
    (match) => match.group(1) ?? '',
  );

  // Also handle old [#@UUID] format (in case there's old data)
  processed = processed.replaceAllMapped(
    RegExp(
      r'\[#@[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\]',
    ),
    (match) => 'mention', // Generic fallback for old format without name
  );

  return processed;
}

/// Find and add attributions for a mention in a document
void _addMentionAttributions(MutableDocument document, _MentionInfo mention) {
  for (int i = 0; i < document.nodeCount; i++) {
    final node = document.getNodeAt(i);
    if (node is! TextNode) continue;

    final text = node.text.toPlainText();
    int searchIndex = 0;

    while (true) {
      final index = text.indexOf(mention.name, searchIndex);
      if (index == -1) break;

      // Add attribution for this occurrence
      final attribution = CommittedEditorMentionAttribution(
        actorId: mention.actorId,
        username: mention.name,
      );

      // Create a copy of the text and add the attribution
      final newText = node.text.copy();
      newText.addAttribution(
        attribution,
        SpanRange(index, index + mention.name.length - 1),
      );

      document.replaceNodeById(
        node.id,
        ParagraphNode(id: node.id, text: newText, metadata: node.metadata),
      );

      searchIndex = index + mention.name.length;
      break; // Only attribute first occurrence per node
    }
  }
}

/// Trim trailing newlines from code block nodes
void _trimCodeBlockTrailingNewlines(MutableDocument document) {
  for (int i = 0; i < document.nodeCount; i++) {
    final node = document.getNodeAt(i);
    if (node is! TextNode) continue;

    // Check if this is a code block node by metadata
    final blockType = node.metadata['blockType'];
    if (blockType != codeAttribution) continue;

    // Trim trailing whitespace from code block content
    final text = node.text.toPlainText();
    final trimmedText = text.trimRight();

    if (text != trimmedText) {
      // Create new text with trimmed content, preserving attributions
      final newText = AttributedText(trimmedText);

      // Copy attributions that still fit within the trimmed text
      if (trimmedText.isNotEmpty) {
        final spans = node.text.getAttributionSpansInRange(
          attributionFilter: (attr) => true,
          range: SpanRange(0, trimmedText.length - 1),
        );
        for (final span in spans) {
          final endIndex = span.end < trimmedText.length
              ? span.end
              : trimmedText.length - 1;
          if (span.start <= endIndex) {
            newText.addAttribution(
              span.attribution,
              SpanRange(span.start, endIndex),
            );
          }
        }
      }

      // Replace the node with trimmed content
      document.replaceNodeById(
        node.id,
        ParagraphNode(id: node.id, text: newText, metadata: node.metadata),
      );
    }
  }
}

/// Deserialize markdown with mentions into a MutableDocument
MutableDocument _deserializeMarkdownWithMentions(String markdown) {
  // Extract mentions before preprocessing
  final mentions = _extractMentions(markdown);

  // Preprocess markdown to remove mention syntax
  final preprocessed = _preprocessMarkdown(markdown);

  // Deserialize to base document
  final baseDocument = deserializeMarkdownToDocument(preprocessed);
  final document = MutableDocument(nodes: baseDocument.toList());

  // Trim trailing newlines from code blocks
  _trimCodeBlockTrailingNewlines(document);

  // Add mention attributions
  for (final mention in mentions) {
    _addMentionAttributions(document, mention);
  }

  return document;
}

/// A unified item for the mention popover, representing either a twist or a contact.
class MentionItem {
  const MentionItem({
    required this.id,
    required this.name,
    this.isTwist = false,
    this.isContact = false,
  });

  /// Create from a PriorityTwist
  factory MentionItem.fromTwist(PriorityTwist twist) =>
      MentionItem(id: twist.id.toString(), name: twist.name, isTwist: true);

  /// Create from an Actor
  factory MentionItem.fromActor(Actor actor) => MentionItem(
    id: actor.id.toString(),
    name: actor.nameOrEmail,
    isContact: actor.type == ActorType.contact,
  );

  final String id;
  final String name;
  final bool isTwist;
  final bool isContact;
}

class Editor extends StatefulWidget {
  const Editor({
    this.hint,
    this.autofocus = false,
    this.onSubmitted,
    this.onChange,
    this.onIsEmptyChanged,
    this.focusNode,
    this.twists = const [],
    this.actors = const [],
    this.shrinkWrap = true,
    this.initialContent,
    super.key,
  });

  final String? hint;
  final bool autofocus;
  final void Function(String value, {bool alt})? onSubmitted;
  final ValueChanged<String>? onChange;
  final ValueChanged<bool>? onIsEmptyChanged;
  final FocusNode? focusNode;
  final List<PriorityTwist> twists;
  final List<Actor> actors;
  final bool shrinkWrap;
  final String? initialContent;

  @override
  State<Editor> createState() => EditorState();
}

class EditorState extends State<Editor> {
  /// The most recently focused editor instance. Used by the platform menu bar
  /// to dispatch edit operations (cut/copy/paste/undo/redo/selectAll).
  /// Kept on blur so menu item clicks (which steal focus first) still work.
  /// Cleared only on dispose or when a different editor gains focus.
  static EditorState? activeInstance;

  final GlobalKey _docLayoutKey = GlobalKey();
  late FocusNode _editorFocusNode;
  late ScrollController _scrollController;
  late MutableDocument _document;
  late MutableDocumentComposer _composer;
  late super_editor.Editor _editor;
  final Debouncer _debouncer = Debouncer();
  bool _isEmpty = true;

  // User mention functionality
  late EditorMentionDetector _mentionDetector;
  late final LeaderLink _mentionLeaderLink;
  final OverlayPortalController _mentionOverlayController =
      OverlayPortalController();
  bool _showMentionPopoverAbove = false;
  final GlobalKey<EditorMentionPopoverState> _mentionPopoverKey =
      GlobalKey<EditorMentionPopoverState>();

  // Link editing functionality
  late EditorLinkDetector _linkDetector;
  late final LeaderLink _linkLeaderLink;
  final OverlayPortalController _linkOverlayController =
      OverlayPortalController();
  bool _showLinkToolbarAbove = false;
  bool _listenersAttached = false;
  // Saved state for restoring selection after link modal closes
  DocumentSelection? _savedSelection;
  LinkAttribution? _savedExistingLink;
  SpanRange? _savedLinkSpanRange;
  String? _savedLinkNodeId;

  /// Returns the appropriate gesture mode based on the current platform
  DocumentGestureMode get _gestureMode {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return DocumentGestureMode.android;
      case TargetPlatform.iOS:
        return DocumentGestureMode.iOS;
      default:
        return DocumentGestureMode.mouse;
    }
  }

  /// Returns the appropriate input source based on the current platform
  TextInputSource get _inputSource {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return TextInputSource.ime;
      default:
        return TextInputSource.keyboard;
    }
  }

  void clear() {
    setState(() {
      _editor.execute([ClearDocumentRequest()]);
    });
  }

  /// Resets the editor by clearing it and re-initializing with new content
  void reset(String? content) {
    setState(() {
      final requests = <EditRequest>[
        const ChangeSelectionRequest(
          null,
          SelectionChangeType.clearSelection,
          SelectionReason.contentChange,
        ),
      ];

      if (content != null && content.isNotEmpty) {
        final newDocument = _deserializeMarkdownWithMentions(content);

        // Delete all existing nodes
        for (int i = _document.nodeCount - 1; i >= 0; i--) {
          final node = _document.getNodeAt(i);
          if (node != null) {
            requests.add(DeleteNodeRequest(nodeId: node.id));
          }
        }

        // Insert all nodes from new document
        int index = 0;
        for (final node in newDocument.toList()) {
          requests.add(InsertNodeAtIndexRequest(
            nodeIndex: index++,
            newNode: node,
          ));
        }
      } else {
        requests.add(ClearDocumentRequest());
      }

      _editor.execute(requests);

      // Update isEmpty state
      _isEmpty = serializeDocumentToMarkdown(_document).isEmpty;
    });
  }

  /// Inserts text at the current cursor position
  void insertTextAtCursor(String text) {
    log.info("Inserting text at cursor: $text");
    if (text.isEmpty) return;

    setState(() {
      // Get current cursor position
      final selection = _composer.selection;
      if (selection == null) {
        // If no selection, append to the end of the document
        final lastNode = _document.getNodeAt(_document.nodeCount - 1);
        if (lastNode != null) {
          final position = DocumentPosition(
            nodeId: lastNode.id,
            nodePosition: lastNode.endPosition,
          );
          _editor.execute([
            InsertTextRequest(
              documentPosition: position,
              textToInsert: text,
              attributions: {},
            ),
          ]);
        }
      } else {
        // Insert at current cursor position
        _editor.execute([
          InsertTextRequest(
            documentPosition: selection.extent,
            textToInsert: text,
            attributions: {},
          ),
        ]);
      }
    });
  }

  void _onDocumentChanged(DocumentChangeLog _) {
    _debouncer.debounce(
      duration: const Duration(milliseconds: 2000),
      onDebounce: notify,
    );
  }

  void notify() {
    _debouncer.cancel();
    final md = _serializeWithMentions(_document);
    widget.onChange?.call(md);
  }

  /// Custom markdown serializer that converts mentions from name to [Name](#@ID)
  String _serializeWithMentions(MutableDocument document) {
    // First serialize normally
    String markdown = serializeDocumentToMarkdown(document);

    // Then walk through the document to find mention attributions and replace
    for (int i = 0; i < document.nodeCount; i++) {
      final node = document.getNodeAt(i);
      if (node is! TextNode) continue;

      final text = node.text;
      if (text.length == 0) continue;

      final spans = text.getAttributionSpansInRange(
        attributionFilter: (attr) => attr is CommittedEditorMentionAttribution,
        range: SpanRange(0, text.length - 1),
      );

      // Process spans in reverse order to maintain string positions
      final spansList = spans.toList()
        ..sort((a, b) => b.start.compareTo(a.start));

      for (final span in spansList) {
        final attribution =
            span.attribution as CommittedEditorMentionAttribution;
        final mentionText = text.substring(span.start, span.end + 1);

        // Replace name with [Name](#@ID)
        final name = attribution.username;
        final replacement = '[$name](#@${attribution.actorId})';
        markdown = markdown.replaceFirst(mentionText, replacement);
      }
    }

    return markdown;
  }

  void _onFocusChange() {
    if (_editorFocusNode.hasFocus) {
      activeInstance = this;
    } else {
      // Don't clear activeInstance on blur — the menu bar steals focus before
      // onSelected fires. The reference is cleared on dispose or when another
      // editor gains focus.
      notify();
    }
  }

  void _onDocumentChange(List<EditEvent> changeList) {
    final isEmpty = serializeDocumentToMarkdown(_document).isEmpty;
    setState(() {
      _isEmpty = isEmpty;
    });
    // Notify parent immediately for instant UI updates
    widget.onIsEmptyChanged?.call(isEmpty);
  }

  late final _documentChangeListener = FunctionalEditListener(
    _onDocumentChange,
  );

  @override
  void initState() {
    super.initState();

    // Initialize document with content if provided
    if (widget.initialContent != null && widget.initialContent!.isNotEmpty) {
      _document = _deserializeMarkdownWithMentions(widget.initialContent!);
    } else {
      _document = MutableDocument.empty();
    }

    _document.addListener(_onDocumentChanged);
    _composer = MutableDocumentComposer();
    _editorFocusNode = widget.focusNode ?? FocusNode();
    _editorFocusNode.addListener(_onFocusChange);
    _editor = createDefaultDocumentEditor(
      document: _document,
      composer: _composer,
      isHistoryEnabled: true,
    );
    _editor.addListener(_documentChangeListener);
    _scrollController = ScrollController();

    // Initialize user mention detector
    _mentionDetector = EditorMentionDetector(
      document: _document,
      composer: _composer,
      editor: _editor,
    );
    _mentionLeaderLink = LeaderLink();

    // Initialize link detector
    _linkDetector = EditorLinkDetector(
      document: _document,
      composer: _composer,
    );
    _linkLeaderLink = LeaderLink();

    // Don't call clear() if we have initial content
    // Defer clear until after first frame to ensure SuperEditor layout is ready
    if (widget.initialContent == null || widget.initialContent!.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          clear();
        }
      });
    }
  }

  @override
  void didUpdateWidget(Editor oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Update document if initialContent changed from empty to non-empty
    if (oldWidget.initialContent != widget.initialContent &&
        widget.initialContent != null &&
        widget.initialContent!.isNotEmpty) {
      // Only update if document is currently empty (avoid overwriting user edits)
      if (_document.nodeCount == 1 &&
          _document.getNodeAt(0) is ParagraphNode &&
          (_document.getNodeAt(0) as ParagraphNode).text
              .toPlainText()
              .isEmpty) {
        // Deserialize new content
        final newDocument = _deserializeMarkdownWithMentions(
          widget.initialContent!,
        );

        // Replace document nodes using editor commands (not direct mutation)
        // to keep the presenter pipeline in sync and avoid null check failures
        // in SuperEditor's selection styler on focus changes.
        setState(() {
          final requests = <EditRequest>[
            const ChangeSelectionRequest(
              null,
              SelectionChangeType.clearSelection,
              SelectionReason.contentChange,
            ),
          ];

          // Delete all existing nodes
          for (int i = _document.nodeCount - 1; i >= 0; i--) {
            final node = _document.getNodeAt(i);
            if (node != null) {
              requests.add(DeleteNodeRequest(nodeId: node.id));
            }
          }

          // Insert all nodes from new document
          int index = 0;
          for (final node in newDocument.toList()) {
            requests.add(InsertNodeAtIndexRequest(
              nodeIndex: index++,
              newNode: node,
            ));
          }

          _editor.execute(requests);
        });
      }
    }
  }

  @override
  void dispose() {
    if (activeInstance == this) activeInstance = null;
    _editor.removeListener(_documentChangeListener);
    _editorFocusNode.removeListener(_onFocusChange);
    _mentionDetector.removeListener(_updateMentionOverlay);
    _linkDetector.removeListener(_updateLinkOverlay);
    _debouncer.cancel();
    _scrollController.dispose();
    // Only dispose the FocusNode if we created it
    if (widget.focusNode == null) {
      _editorFocusNode.dispose();
    }
    _mentionDetector.dispose();
    _linkDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = context.colour.brightness == Brightness.dark;
    final settingsState = context.watch<SettingsBloc>().state;

    return OverlayPortal(
      controller: _linkOverlayController,
      overlayChildBuilder: _buildEditorLinkToolbar,
      child: OverlayPortal(
        controller: _mentionOverlayController,
        overlayChildBuilder: _buildEditorMentionPopover,
        child: Shortcuts(
          shortcuts: _isEmpty
              ? const <ShortcutActivator, Intent>{
                  // When empty, shortcuts are handled at the page level
                }
              : _buildShortcuts(settingsState.enterBehavior),
          child: Actions(
            actions: <Type, Action<Intent>>{
              SubmitIntent: CallbackAction<SubmitIntent>(
                onInvoke: (SubmitIntent intent) {
                  _submitFromKeyboard(intent.alt);
                  return KeyEventResult.handled;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _editorFocusNode.requestFocus(),
              child: SuperEditor(
                inputRole: 'plot-note-editor',
                autofocus: widget.autofocus,
                editor: _editor,
                focusNode: _editorFocusNode,
                shrinkWrap: widget.shrinkWrap,
                scrollController: _scrollController,
                documentLayoutKey: _docLayoutKey,
                inputSource: _inputSource,
                gestureMode: _gestureMode,
                documentOverlayBuilders: [
                  // Platform-specific overlays for mobile
                  if (defaultTargetPlatform == TargetPlatform.android) ...[
                    SuperEditorAndroidHandlesDocumentLayerBuilder(
                      caretColor: context.theme.colors.mutedForeground,
                    ),
                    SuperEditorAndroidToolbarFocalPointDocumentLayerBuilder(),
                  ] else if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                    SuperEditorIosHandlesDocumentLayerBuilder(),
                    SuperEditorIosToolbarFocalPointDocumentLayerBuilder(),
                  ] else ...[
                    DefaultCaretOverlayBuilder(
                      caretStyle: CaretStyle().copyWith(
                        color: context.theme.colors.mutedForeground,
                      ),
                    ),
                  ],
                  // Position leader at caret for mention popover
                  _buildMentionLeaderOverlay,
                  // Position leader at selection extent for link toolbar
                  _buildLinkLeaderOverlay,
                ],
                stylesheet: _buildStylesheet(context, isDark),
                selectionStyle: SelectionStyles(
                  selectionColor: context.theme.colors.primaryForeground,
                ),
                componentBuilders: [
                  if (widget.hint != null)
                    HintComponentBuilder(
                      widget.hint!,
                      (context) => _baseTextStyle(
                        context,
                      ).copyWith(color: context.theme.plotColors.muted),
                    ),
                  PlotTaskComponentBuilder(_editor),
                  ...defaultComponentBuilders,
                ],
                keyboardActions: [
                  _bubbleOverrideKeys,
                  if (_isEmpty) _bubbleArrowKeys,
                  _handleMentionPopoverNavigation,
                  _buildEnterKeyHandler(settingsState.enterBehavior),
                  _handlePunctuationAfterMention,
                  _handleBackspaceOverMention,
                  _handleCmdKForLink,
                  _handleSmartPaste,
                  // Use IME keyboard actions on mobile, regular keyboard actions on desktop
                  ...(_inputSource == TextInputSource.ime
                      ? defaultImeKeyboardActions
                      : defaultKeyboardActions),
                  _bubbleSpecialKeys, // Process meta key combos first to allow propagation
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Submit from keyboard (Enter key) - includes first-time prompt check
  void _submitFromKeyboard(bool alt) async {
    // Don't show prompt or submit if selecting a mention
    if (_mentionDetector.composingMention != null) {
      return;
    }

    // Show first-time prompt if needed (only on devices with physical keyboards)
    final settingsBloc = context.read<SettingsBloc>();
    if (hasPhysicalKeyboard() &&
        !settingsBloc.state.hasBeenPromptedForEnterBehavior) {
      final result = await ChangeEnterBehavior().run(context);

      // If user cancelled the prompt, do nothing (ignore the Enter press)
      if (result is CommandSkipped) {
        return;
      }

      // After prompt, complete the original action based on user's selection
      if (!mounted) return;
      final selectedBehavior = settingsBloc.state.enterBehavior;

      if (selectedBehavior == EnterBehavior.enterSubmits) {
        // User chose Enter to submit, so submit now
        submit(alt);
      } else {
        // User chose Enter for newline, so insert newline
        _editor.execute([InsertNewlineAtCaretRequest()]);
      }
      return;
    }

    submit(alt);
  }

  /// Submit the editor content (called by save buttons and keyboard)
  void submit(bool alt) async {
    final md = _serializeWithMentions(_document);
    widget.onSubmitted?.call(md, alt: alt);
  }

  /// Build shortcuts based on enter key behavior setting
  Map<ShortcutActivator, Intent> _buildShortcuts(EnterBehavior behavior) {
    switch (behavior) {
      case EnterBehavior.enterSubmits:
        // Mode 1: Enter=Submit, Shift-Enter=Newline, Cmd-Enter=Submit+DoNow
        return {
          const SingleActivator(LogicalKeyboardKey.enter): SubmitIntent(),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              SubmitIntent(alt: true),
        };
      case EnterBehavior.enterNewline:
        // Mode 2: Enter=Newline, Shift-Enter=Newline, Cmd-Enter=Submit
        return {
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              SubmitIntent(),
        };
    }
  }

  /// Build enter key handler based on behavior setting
  SuperEditorKeyboardAction _buildEnterKeyHandler(EnterBehavior behavior) {
    return ({
      required SuperEditorContext editContext,
      required KeyEvent keyEvent,
    }) {
      if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
        return ExecutionInstruction.continueExecution;
      }

      if (keyEvent.logicalKey != LogicalKeyboardKey.enter &&
          keyEvent.logicalKey != LogicalKeyboardKey.numpadEnter) {
        return ExecutionInstruction.continueExecution;
      }

      // On mobile devices (without physical keyboards), Enter always adds newline
      if (!hasPhysicalKeyboard()) {
        // Allow plain Enter to insert newline
        if (!HardwareKeyboard.instance.isMetaPressed &&
            !HardwareKeyboard.instance.isControlPressed) {
          editContext.editor.execute([InsertNewlineAtCaretRequest()]);
          return ExecutionInstruction.haltExecution;
        }
        // Block Cmd-Enter (let it bubble up to shortcuts)
        return ExecutionInstruction.blocked;
      }

      switch (behavior) {
        case EnterBehavior.enterSubmits:
          // Mode 1: Block plain Enter (handled by Shortcuts), allow Shift-Enter
          if (!HardwareKeyboard.instance.isShiftPressed) {
            return ExecutionInstruction.blocked;
          }
          // Shift-Enter: insert newline
          editContext.editor.execute([InsertNewlineAtCaretRequest()]);
          return ExecutionInstruction.haltExecution;

        case EnterBehavior.enterNewline:
          // Mode 2: Allow plain Enter to insert newline, block Cmd-Enter
          if (HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isControlPressed) {
            return ExecutionInstruction.blocked;
          }
          // Plain Enter or Shift-Enter: insert newline
          editContext.editor.execute([InsertNewlineAtCaretRequest()]);
          return ExecutionInstruction.haltExecution;
      }
    };
  }

  /// Get the current editor content as markdown
  String serialize() {
    return _serializeWithMentions(_document);
  }

  // -- Edit operations for platform menu bar --

  CommonEditorOperations get _commonOps => CommonEditorOperations(
    document: _document,
    editor: _editor,
    composer: _composer,
    documentLayoutResolver: () => _docLayoutKey.currentState as DocumentLayout,
  );

  void performCut() {
    _commonOps.cut();
    _editorFocusNode.requestFocus();
  }

  void performCopy() {
    _commonOps.copy();
    _editorFocusNode.requestFocus();
  }

  void performPaste() {
    _commonOps.paste();
    _editorFocusNode.requestFocus();
  }

  void performSelectAll() {
    _commonOps.selectAll();
    _editorFocusNode.requestFocus();
  }

  /// Builds a leader overlay at the caret position for the mention popover to follow
  SuperEditorLayerBuilder get _buildMentionLeaderOverlay {
    return MentionLeaderLayerBuilder(
      mentionDetector: _mentionDetector,
      composer: _composer,
      leaderLink: _mentionLeaderLink,
      onPositionChanged: (bool showAbove) {
        if (_showMentionPopoverAbove != showAbove) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _showMentionPopoverAbove = showAbove;
              });
            }
          });
        }
      },
    );
  }

  /// Keyboard action that handles navigation when mention popover is visible
  SuperEditorKeyboardAction get _handleMentionPopoverNavigation {
    return ({
      required SuperEditorContext editContext,
      required KeyEvent keyEvent,
    }) {
      if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
        return ExecutionInstruction.continueExecution;
      }

      // Only handle keys when mention is being composed
      if (_mentionDetector.composingMention == null) {
        return ExecutionInstruction.continueExecution;
      }

      // Get the popover state
      final popoverState = _mentionPopoverKey.currentState;
      if (popoverState == null) {
        return ExecutionInstruction.continueExecution;
      }

      // Handle navigation keys
      switch (keyEvent.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          popoverState.navigateUp();
          return ExecutionInstruction.haltExecution;

        case LogicalKeyboardKey.arrowDown:
          popoverState.navigateDown();
          return ExecutionInstruction.haltExecution;

        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
        case LogicalKeyboardKey.tab:
          popoverState.selectCurrent();
          return ExecutionInstruction.haltExecution;

        case LogicalKeyboardKey.escape:
          popoverState.cancel();
          return ExecutionInstruction.haltExecution;

        default:
          return ExecutionInstruction.continueExecution;
      }
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_listenersAttached) {
      _listenersAttached = true;
      // Listen to mention detector to show/hide overlay
      _mentionDetector.addListener(_updateMentionOverlay);
      // Listen to link detector to show/hide link toolbar
      _linkDetector.addListener(_updateLinkOverlay);
    }
  }

  /// Build the combined mention items list from twists and actors
  List<MentionItem> _buildMentionItems() {
    // Filter out connectors that don't handle replies or aren't connected
    final mentionableTwists = widget.twists
        .where((t) => !t.isSource || (t.defaultMentionCreated && t.userConnected));
    // Twists first, then actors (excluding actors that are already represented by twists)
    final twistActorIds = mentionableTwists.map((t) => t.id.toString()).toSet();
    return [
      ...mentionableTwists.map(MentionItem.fromTwist),
      ...widget.actors
          .where((actor) => !twistActorIds.contains(actor.id.toString()))
          .map(MentionItem.fromActor),
    ];
  }

  void _updateMentionOverlay() {
    final mention = _mentionDetector.composingMention;

    // Filter mention items based on composing text
    final hasMatches =
        mention != null &&
        _buildMentionItems().any(
          (item) =>
              item.name.toLowerCase().contains(mention.text.toLowerCase()),
        );

    if (hasMatches && !_mentionOverlayController.isShowing) {
      _mentionOverlayController.show();
    } else if (!hasMatches && _mentionOverlayController.isShowing) {
      // Check if we're in the layout phase - if so, defer hiding the overlay
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _mentionOverlayController.isShowing) {
            _mentionOverlayController.hide();
          }
        });
      } else {
        _mentionOverlayController.hide();
      }
    }
  }

  /// Builds the user mention popover in the overlay
  Widget _buildEditorMentionPopover(BuildContext context) {
    final mentionBeingComposed = _mentionDetector.composingMention;
    final mentionItems = _buildMentionItems();
    if (mentionBeingComposed == null || mentionItems.isEmpty) {
      return const SizedBox.shrink();
    }

    // Sort items by most-recently-used
    final localPrefs = context.read<LocalPreferencesBloc>();
    final sortedItems = localPrefs.sortByMentionMru(
      mentionItems,
      (item) => item.id,
      isLowPriority: (item) => item.isContact,
    );

    return EditorMentionPopover(
      key: _mentionPopoverKey,
      editorFocusNode: _editorFocusNode,
      leaderLink: _mentionLeaderLink,
      items: sortedItems,
      composingText: mentionBeingComposed.text,
      showAbove: _showMentionPopoverAbove,
      onItemSelected: (item) {
        // Record mention usage for MRU sorting
        localPrefs.recordMentionUsage(item.id);

        _mentionDetector.completeMention(actorId: item.id, username: item.name);
        _editorFocusNode.requestFocus();
      },
      onCancelRequested: () {
        _mentionDetector.cancelMention();
        _editorFocusNode.requestFocus();
      },
    );
  }

  // --- Link editing ---

  void _updateLinkOverlay() {
    final shouldShow = _linkDetector.shouldShowToolbar;

    // Hide link toolbar when mention popover is active
    if (_mentionDetector.composingMention != null) {
      if (_linkOverlayController.isShowing) {
        _hideLinkOverlay();
      }
      return;
    }

    if (shouldShow && !_linkOverlayController.isShowing) {
      _linkOverlayController.show();
    } else if (!shouldShow && _linkOverlayController.isShowing) {
      _hideLinkOverlay();
    }
  }

  void _hideLinkOverlay() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _linkOverlayController.isShowing) {
          _linkOverlayController.hide();
        }
      });
    } else {
      _linkOverlayController.hide();
    }
  }

  Widget _buildEditorLinkToolbar(BuildContext context) {
    if (!_linkDetector.shouldShowToolbar) {
      return const SizedBox.shrink();
    }

    return EditorLinkToolbar(
      editorFocusNode: _editorFocusNode,
      leaderLink: _linkLeaderLink,
      showAbove: _showLinkToolbarAbove,
      hasExistingLink: _linkDetector.existingLink != null,
      onLinkTapped: _openLinkModal,
    );
  }

  /// Builds a leader overlay at the selection extent for the link toolbar
  SuperEditorLayerBuilder get _buildLinkLeaderOverlay {
    return LinkLeaderLayerBuilder(
      linkDetector: _linkDetector,
      composer: _composer,
      leaderLink: _linkLeaderLink,
      onPositionChanged: (bool showAbove) {
        if (_showLinkToolbarAbove != showAbove) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _showLinkToolbarAbove = showAbove;
              });
            }
          });
        }
      },
    );
  }

  void _openLinkModal() {
    // Save current state before modal steals focus
    _savedSelection = _composer.selection;
    _savedExistingLink = _linkDetector.existingLink;
    _savedLinkSpanRange = _linkDetector.linkSpanRange;
    _savedLinkNodeId = _linkDetector.linkNodeId;

    final existingUrl = _savedExistingLink?.plainTextUri;

    // Hide the link toolbar while modal is open
    if (_linkOverlayController.isShowing) {
      _linkOverlayController.hide();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final result = await EditorLinkModal(
        existingUrl: existingUrl,
      ).run(context);

      if (!mounted) return;

      // Restore editor focus and selection
      _editorFocusNode.requestFocus();

      if (_savedSelection != null) {
        _editor.execute([
          ChangeSelectionRequest(
            _savedSelection!,
            SelectionChangeType.placeCaret,
            SelectionReason.userInteraction,
          ),
        ]);
      }

      if (result is LinkModalApply) {
        _applyLink(result.url);
      } else if (result is LinkModalRemove) {
        _removeLink();
      }

      // Clear saved state
      _savedSelection = null;
      _savedExistingLink = null;
      _savedLinkSpanRange = null;
      _savedLinkNodeId = null;
    });
  }

  void _applyLink(String url) {
    if (_savedExistingLink != null &&
        _savedLinkSpanRange != null &&
        _savedLinkNodeId != null) {
      // Editing existing link: remove old, add new
      final range = DocumentRange(
        start: DocumentPosition(
          nodeId: _savedLinkNodeId!,
          nodePosition: TextNodePosition(offset: _savedLinkSpanRange!.start),
        ),
        end: DocumentPosition(
          nodeId: _savedLinkNodeId!,
          nodePosition: TextNodePosition(offset: _savedLinkSpanRange!.end + 1),
        ),
      );

      _editor.execute([
        RemoveTextAttributionsRequest(
          documentRange: range,
          attributions: {_savedExistingLink!},
        ),
        AddTextAttributionsRequest(
          documentRange: range,
          attributions: {LinkAttribution(url)},
        ),
      ]);
    } else if (_savedSelection != null && !_savedSelection!.isCollapsed) {
      // New link on selected text
      _editor.execute([
        AddTextAttributionsRequest(
          documentRange: _savedSelection!,
          attributions: {LinkAttribution(url)},
        ),
      ]);
    }
  }

  void _removeLink() {
    if (_savedExistingLink != null &&
        _savedLinkSpanRange != null &&
        _savedLinkNodeId != null) {
      final range = DocumentRange(
        start: DocumentPosition(
          nodeId: _savedLinkNodeId!,
          nodePosition: TextNodePosition(offset: _savedLinkSpanRange!.start),
        ),
        end: DocumentPosition(
          nodeId: _savedLinkNodeId!,
          nodePosition: TextNodePosition(offset: _savedLinkSpanRange!.end + 1),
        ),
      );

      _editor.execute([
        RemoveTextAttributionsRequest(
          documentRange: range,
          attributions: {_savedExistingLink!},
        ),
      ]);
    }
  }

  /// Keyboard action: Cmd+K opens link modal when context is appropriate,
  /// otherwise falls through to let the command modal handle it.
  ExecutionInstruction _handleCmdKForLink({
    required SuperEditorContext editContext,
    required KeyEvent keyEvent,
  }) {
    if (keyEvent is! KeyDownEvent) {
      return ExecutionInstruction.continueExecution;
    }

    if (keyEvent.logicalKey != LogicalKeyboardKey.keyK) {
      return ExecutionInstruction.continueExecution;
    }

    final isMetaPressed =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (!isMetaPressed) {
      return ExecutionInstruction.continueExecution;
    }

    // Don't handle if shift is also pressed (Cmd+Shift+K is a different shortcut)
    if (HardwareKeyboard.instance.isShiftPressed) {
      return ExecutionInstruction.continueExecution;
    }

    if (_linkDetector.shouldShowToolbar) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openLinkModal();
        }
      });
      return ExecutionInstruction.haltExecution;
    }

    // Fall through to let _bubbleSpecialKeys handle it (bubbles to CommandScope)
    return ExecutionInstruction.continueExecution;
  }

  /// Keyboard action: Smart paste - Cmd+V with selected text and a URL on
  /// clipboard applies the URL as a link attribution to the selected text.
  ExecutionInstruction _handleSmartPaste({
    required SuperEditorContext editContext,
    required KeyEvent keyEvent,
  }) {
    if (keyEvent is! KeyDownEvent) {
      return ExecutionInstruction.continueExecution;
    }

    if (keyEvent.logicalKey != LogicalKeyboardKey.keyV) {
      return ExecutionInstruction.continueExecution;
    }

    final isMetaPressed =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (!isMetaPressed) {
      return ExecutionInstruction.continueExecution;
    }

    final selection = editContext.composer.selection;
    if (selection == null) {
      return ExecutionInstruction.continueExecution;
    }

    // For collapsed selections, only intercept for Plot URLs
    if (selection.isCollapsed) {
      return _handleCollapsedPaste();
    }

    // Halt execution and handle async clipboard read for selections
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final clipboardData = await Clipboard.getData('text/plain');
      final text = clipboardData?.text?.trim();

      if (text != null && text.isNotEmpty && _isUrl(text)) {
        // Apply link attribution to selected text
        final currentSelection = _composer.selection;
        if (currentSelection != null && !currentSelection.isCollapsed) {
          _editor.execute([
            AddTextAttributionsRequest(
              documentRange: currentSelection,
              attributions: {LinkAttribution(text)},
            ),
          ]);
        }
      } else {
        _normalPaste();
      }
    });

    return ExecutionInstruction.haltExecution;
  }

  /// Handle paste when selection is collapsed — inserts the URL immediately,
  /// then replaces it with the resolved page title once fetched.
  ExecutionInstruction _handleCollapsedPaste() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final clipboardData = await Clipboard.getData('text/plain');
      final text = clipboardData?.text?.trim();

      if (text == null || text.isEmpty || !_isUrl(text)) {
        _normalPaste();
        return;
      }

      // Insert the raw URL immediately so the user sees feedback
      final insertPosition = _composer.selection;
      if (insertPosition == null) return;
      final nodeId = insertPosition.extent.nodeId;
      final startOffset =
          (insertPosition.extent.nodePosition as TextNodePosition).offset;

      _editor.execute([
        InsertTextRequest(
          documentPosition: insertPosition.extent,
          textToInsert: text,
          attributions: {LinkAttribution(text)},
        ),
      ]);

      // Resolve the title for the URL
      String? title;
      final plotLink = OpenPageLink.parse(text);
      if (plotLink != null) {
        // Internal Plot link — look up locally
        try {
          if (plotLink.threadId != null) {
            final thread = await Thread.getOne(
              Uuid.fromShortString(plotLink.threadId!),
            );
            title = thread.title;
          }
          if (title == null && plotLink.priorityId != null) {
            final priority = await store.Priority.getOne(
              Uuid.fromShortString(plotLink.priorityId!),
            );
            title = priority.title;
          }
        } catch (_) {
          // Fall back — raw URL is already shown
        }
      } else {
        // External link — fetch page title
        title = await fetchUrlTitle(text);
      }

      if (!mounted || title == null) return;

      // Replace the raw URL text with the resolved title
      final endOffset = startOffset + text.length;
      _editor.execute([
        DeleteContentRequest(
          documentRange: DocumentRange(
            start: DocumentPosition(
              nodeId: nodeId,
              nodePosition: TextNodePosition(offset: startOffset),
            ),
            end: DocumentPosition(
              nodeId: nodeId,
              nodePosition: TextNodePosition(offset: endOffset),
            ),
          ),
        ),
        InsertTextRequest(
          documentPosition: DocumentPosition(
            nodeId: nodeId,
            nodePosition: TextNodePosition(offset: startOffset),
          ),
          textToInsert: title,
          attributions: {LinkAttribution(text)},
        ),
      ]);
    });

    return ExecutionInstruction.haltExecution;
  }

  void _normalPaste() {
    CommonEditorOperations(
      document: _document,
      editor: _editor,
      composer: _composer,
      documentLayoutResolver: () =>
          _docLayoutKey.currentState as DocumentLayout,
    ).paste();
  }

  /// Check if text looks like a URL
  static bool _isUrl(String text) {
    final uri = Uri.tryParse(text);
    if (uri == null) return false;
    return uri.hasScheme &&
        (uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'mailto');
  }
}

/// Layer builder that positions a leader at the caret for the mention popover
class MentionLeaderLayerBuilder implements SuperEditorLayerBuilder {
  const MentionLeaderLayerBuilder({
    required this.mentionDetector,
    required this.composer,
    required this.leaderLink,
    required this.onPositionChanged,
  });

  final EditorMentionDetector mentionDetector;
  final DocumentComposer composer;
  final LeaderLink leaderLink;
  final void Function(bool showAbove) onPositionChanged;

  @override
  ContentLayerWidget build(
    BuildContext context,
    SuperEditorContext editContext,
  ) {
    final mentionBeingComposed = mentionDetector.composingMention;
    if (mentionBeingComposed == null) {
      return ContentLayerProxyWidget(
        key: const ValueKey('mention_leader_empty'),
        child: const SizedBox.shrink(),
      );
    }

    final selection = composer.selection;
    if (selection == null) {
      return ContentLayerProxyWidget(
        key: const ValueKey('mention_leader_no_selection'),
        child: const SizedBox.shrink(),
      );
    }

    // Get the position of the @ trigger character (not the current caret)
    final triggerPosition = DocumentPosition(
      nodeId: selection.extent.nodeId,
      nodePosition: TextNodePosition(
        offset: mentionBeingComposed.triggerOffset,
      ),
    );

    // Get rect for the @ trigger position
    final docLayout = editContext.documentLayout;
    final triggerRect = docLayout.getRectForPosition(triggerPosition);
    if (triggerRect == null) {
      return ContentLayerProxyWidget(
        key: const ValueKey('mention_leader_no_trigger_rect'),
        child: const SizedBox.shrink(),
      );
    }

    // Find the RenderBox for the document layout
    // The trigger rect is already in document-local coordinates, but we need to find
    // what RenderBox to use for coordinate conversion
    RenderBox? docLayoutBox;
    if (docLayout is State) {
      RenderObject? renderObject = (docLayout as State).context
          .findRenderObject();

      // If it's a sliver, traverse to find a RenderBox child
      RenderObject? current = renderObject;
      int depth = 0;
      while (current != null && depth < 10) {
        if (current is RenderBox) {
          docLayoutBox = current;
          break;
        }

        // Try to get first child
        RenderObject? nextChild;
        current.visitChildren((child) {
          nextChild ??= child;
        });
        current = nextChild;
        depth++;
      }
    }

    if (docLayoutBox == null) {
      // Fallback: use simple below positioning
      return ContentLayerProxyWidget(
        key: const ValueKey('mention_leader'),
        child: Transform.translate(
          offset: Offset(
            triggerRect.left,
            triggerRect.bottom + context.theme.spacing.sm,
          ),
          child: Leader(link: leaderLink, child: const SizedBox()),
        ),
      );
    }

    // Calculate global position to determine available space
    final triggerGlobalOffset = docLayoutBox.localToGlobal(triggerRect.topLeft);

    // Get viewport height
    final viewportHeight = MediaQuery.of(context).size.height;

    // Calculate available space below and above the trigger
    const popoverMaxHeight = 200.0; // From EditorMentionPopover constraints
    final spacing = context.theme.spacing.sm;
    final spaceBelow =
        viewportHeight - triggerGlobalOffset.dy - triggerRect.height;
    final spaceAbove = triggerGlobalOffset.dy;

    // Determine vertical position: prefer below, flip to above if not enough space
    final showAbove =
        !(spaceBelow >= popoverMaxHeight + spacing || spaceBelow >= spaceAbove);

    final verticalOffset = showAbove
        ? triggerRect.top -
              spacing // Place above (flip)
        : triggerRect.bottom + spacing; // Place below

    // Notify about position change
    onPositionChanged(showAbove);

    // Position the leader at the @ symbol (stays fixed as user types)
    return ContentLayerProxyWidget(
      key: const ValueKey('mention_leader'),
      child: Transform.translate(
        offset: Offset(triggerRect.left, verticalOffset),
        child: Leader(link: leaderLink, child: const SizedBox()),
      ),
    );
  }
}

/// Layer builder that positions a leader at the selection extent for the link toolbar
class LinkLeaderLayerBuilder implements SuperEditorLayerBuilder {
  const LinkLeaderLayerBuilder({
    required this.linkDetector,
    required this.composer,
    required this.leaderLink,
    required this.onPositionChanged,
  });

  final EditorLinkDetector linkDetector;
  final DocumentComposer composer;
  final LeaderLink leaderLink;
  final void Function(bool showAbove) onPositionChanged;

  @override
  ContentLayerWidget build(
    BuildContext context,
    SuperEditorContext editContext,
  ) {
    if (!linkDetector.shouldShowToolbar) {
      return ContentLayerProxyWidget(
        key: const ValueKey('link_leader_empty'),
        child: const SizedBox.shrink(),
      );
    }

    final selection = composer.selection;
    if (selection == null) {
      return ContentLayerProxyWidget(
        key: const ValueKey('link_leader_no_selection'),
        child: const SizedBox.shrink(),
      );
    }

    final docLayout = editContext.documentLayout;
    final extentRect = docLayout.getRectForPosition(selection.extent);
    if (extentRect == null) {
      return ContentLayerProxyWidget(
        key: const ValueKey('link_leader_no_rect'),
        child: const SizedBox.shrink(),
      );
    }

    // Find RenderBox for coordinate conversion
    RenderBox? docLayoutBox;
    if (docLayout is State) {
      RenderObject? renderObject = (docLayout as State).context
          .findRenderObject();
      RenderObject? current = renderObject;
      int depth = 0;
      while (current != null && depth < 10) {
        if (current is RenderBox) {
          docLayoutBox = current;
          break;
        }
        RenderObject? nextChild;
        current.visitChildren((child) {
          nextChild ??= child;
        });
        current = nextChild;
        depth++;
      }
    }

    if (docLayoutBox == null) {
      return ContentLayerProxyWidget(
        key: const ValueKey('link_leader'),
        child: Transform.translate(
          offset: Offset(
            extentRect.right,
            extentRect.top - context.theme.spacing.sm - 30,
          ),
          child: Leader(link: leaderLink, child: const SizedBox()),
        ),
      );
    }

    final extentGlobalOffset = docLayoutBox.localToGlobal(extentRect.topLeft);
    final viewportHeight = MediaQuery.of(context).size.height;
    const toolbarHeight = 30.0;
    final spacing = context.theme.spacing.sm;
    final spaceAbove = extentGlobalOffset.dy;
    final spaceBelow =
        viewportHeight - extentGlobalOffset.dy - extentRect.height;

    final showAbove =
        spaceBelow < toolbarHeight + spacing * 2 && spaceAbove > spaceBelow;

    final verticalOffset = showAbove
        ? extentRect.top - spacing
        : extentRect.bottom + spacing;

    onPositionChanged(showAbove);

    return ContentLayerProxyWidget(
      key: const ValueKey('link_leader'),
      child: Transform.translate(
        offset: Offset(extentRect.right + spacing, verticalOffset),
        child: Leader(link: leaderLink, child: const SizedBox()),
      ),
    );
  }
}

class Viewer extends StatefulWidget {
  Viewer({required this.markdown, super.key})
    : document = deserializeMarkdownToDocument(_preprocessMarkdown(markdown));

  final String markdown;
  // final void Function()? onTap;
  final Document document;

  @override
  ViewerState createState() => ViewerState();
}

class ViewerState extends State<Viewer> {
  late super_editor.Editor _editor;

  late final ValueNotifier<DocumentSelection?> _selection;
  final _selectionLayerLinks = SelectionLayerLinks();

  @override
  void initState() {
    super.initState();
    _selection = ValueNotifier<DocumentSelection?>(null);
    _updateDocument();
  }

  void _updateDocument() {
    setState(() {
      final document = _createDocumentWithMentions();
      _editor = createDefaultDocumentEditor(
        document: document,
        composer: MutableDocumentComposer(),
      );
    });
  }

  /// Create document with mention attributions
  MutableDocument _createDocumentWithMentions() {
    return _deserializeMarkdownWithMentions(widget.markdown);
  }

  @override
  void didUpdateWidget(Viewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Check if markdown has changed
    if (oldWidget.markdown != widget.markdown) {
      // Update the document when the markdown changes
      _updateDocument();
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = context.colour.brightness == Brightness.dark;
    return BoxToSliverAdapter(
      child: SuperReader(
        editor: _editor,
        stylesheet: _buildStylesheet(context, isDark),
        // selection: _selection,
        selectionLayerLinks: _selectionLayerLinks,
        selectionStyle: SelectionStyles(
          selectionColor: context.theme.colors.primaryForeground,
        ),
        componentBuilders: <ComponentBuilder>[
          const BlockquoteComponentBuilder(),
          const ParagraphComponentBuilder(),
          const ListItemComponentBuilder(),
          const ImageComponentBuilder(),
          const HorizontalRuleComponentBuilder(),
          PlotTaskComponentBuilder(_editor),
        ],
        contentTapDelegateFactory: (readerContext) =>
            ViewerTapHandler(readerContext.document, context: context),
      ),
    );
  }
}

TextStyle _baseTextStyle(BuildContext context) {
  return context.theme.typography.md.copyWith(height: 1.4);
}

/// Custom inline text styler that applies styling to user mentions
TextStyle _inlineTextStyler(
  Set<Attribution> attributions,
  TextStyle existingStyle,
  BuildContext context,
  bool isDark,
) {
  TextStyle style = defaultInlineTextStyler(attributions, existingStyle);

  // Style composing editor mentions (being typed)
  if (attributions.contains(editorMentionComposingAttribution)) {
    style = style.copyWith(
      color: context.theme.colors.primary,
      fontWeight: FontWeight.w500,
    );
  }

  // Style committed editor mentions
  final committedMention = attributions
      .whereType<CommittedEditorMentionAttribution>()
      .firstOrNull;
  if (committedMention != null) {
    style = style.copyWith(
      color: context.theme.colors.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.none,
    );
  }

  if (attributions.whereType<LinkAttribution>().isNotEmpty) {
    style = style.copyWith(
      color: context.theme.colors.primary,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.none,
    );
  }

  // Apply dark theme base color if no specific attribution styling is applied
  if (isDark &&
      !attributions.contains(editorMentionComposingAttribution) &&
      attributions.whereType<CommittedEditorMentionAttribution>().isEmpty &&
      attributions.whereType<LinkAttribution>().isEmpty) {
    style = style.copyWith(color: context.theme.colors.foreground);
  }

  return style;
}

Stylesheet _buildStylesheet(BuildContext context, bool isDark) {
  final baseStyle = _baseTextStyle(
    context,
  ).copyWith(color: isDark ? context.theme.colors.foreground : null);

  final spacing = context.theme.spacing;
  return Stylesheet(
    rules: [
      // Default spacing for all blocks
      StyleRule(BlockSelector.all, (doc, docNode) {
        return {
          Styles.textStyle: baseStyle,
          Styles.padding: CascadingPadding.only(top: spacing.md),
        };
      }),
      // Remove bottom spacing from last element to prevent container edge gaps
      StyleRule(BlockSelector.all.first(), (doc, docNode) {
        return {Styles.padding: const CascadingPadding.only(top: 0)};
      }),
      // Headers: larger top margin for visual separation, smaller bottom for grouping
      StyleRule(const BlockSelector("header1"), (doc, docNode) {
        return {
          Styles.padding: CascadingPadding.only(
            top: spacing.xxl,
            bottom: spacing.md,
          ),
        };
      }),
      StyleRule(const BlockSelector("header2"), (doc, docNode) {
        return {
          Styles.padding: CascadingPadding.only(
            top: spacing.xxl,
            bottom: spacing.md,
          ),
        };
      }),
      StyleRule(const BlockSelector("header3"), (doc, docNode) {
        return {
          Styles.padding: CascadingPadding.only(
            top: spacing.xxl,
            bottom: spacing.md,
          ),
        };
      }),
      StyleRule(const BlockSelector("header4"), (doc, docNode) {
        return {
          Styles.padding: CascadingPadding.only(
            top: spacing.xxl,
            bottom: spacing.md,
          ),
        };
      }),
      StyleRule(const BlockSelector("listItem"), (doc, docNode) {
        return {Styles.padding: CascadingPadding.only(top: spacing.sm)};
      }),
      // Code blocks with monospace font
      StyleRule(const BlockSelector("code"), (doc, docNode) {
        return {
          Styles.textStyle: baseStyle.copyWith(
            fontFamily:
                'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
            fontSize: baseStyle.fontSize != null
                ? baseStyle.fontSize! * 0.9
                : null,
            height: 1.5,
          ),
          Styles.padding: CascadingPadding.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
        };
      }),
      // Add spacing after the last item in a list (creates spacing after entire list)
      // StyleRule(const BlockSelector("paragraph"), (doc, docNode) {
      //   return {Styles.padding: const CascadingPadding.only(bottom: 14)};
      // }),
    ],
    inlineTextStyler: (attributions, existingStyle) =>
        _inlineTextStyler(attributions, existingStyle, context, isDark),
    inlineWidgetBuilders: defaultInlineWidgetBuilderChain,
  );
}

class SubmitIntent extends Intent {
  const SubmitIntent({this.alt = false});

  final bool alt;
}

class ViewerTapHandler extends SuperReaderLaunchLinkTapHandler {
  ViewerTapHandler(
    super.document, {
    required BuildContext context,
    void Function()? onTap,
  }) : _context = context,
       _handler = onTap;

  final BuildContext _context;
  final void Function()? _handler;

  @override
  MouseCursor? mouseCursorForContentHover(DocumentPosition hoverPosition) {
    return super.mouseCursorForContentHover(hoverPosition) ??
        (_handler != null ? SystemMouseCursors.basic : null);
  }

  @override
  TapHandlingInstruction onTap(DocumentTapDetails details) {
    // Check if tap is on a link and intercept internal Plot links
    final tapPosition = details.documentLayout
        .getDocumentPositionNearestToOffset(details.layoutOffset);
    if (tapPosition != null) {
      final link = _getLinkAtPosition(tapPosition);
      if (link != null) {
        final url = link.toString();
        if (OpenPageLink.parse(url) != null) {
          OpenPageLink(url).run(_context);
          return TapHandlingInstruction.halt;
        }
      }
    }

    final instructions = super.onTap(details);
    if (instructions != TapHandlingInstruction.halt && _handler != null) {
      _handler();
      return TapHandlingInstruction.halt;
    }
    return instructions;
  }

  Uri? _getLinkAtPosition(DocumentPosition position) {
    final nodePosition = position.nodePosition;
    if (nodePosition is! TextNodePosition) return null;

    final textNode = document.getNodeById(position.nodeId);
    if (textNode is! TextNode) return null;

    final tappedAttributions = textNode.text.getAllAttributionsAt(
      nodePosition.offset,
    );
    for (final attribution in tappedAttributions) {
      if (attribution is LinkAttribution) {
        return attribution.launchableUri;
      }
    }
    return null;
  }
}

ExecutionInstruction _bubbleArrowKeys({
  required SuperEditorContext editContext,
  required KeyEvent keyEvent,
}) {
  if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
    return ExecutionInstruction.continueExecution;
  }

  if (keyEvent.logicalKey != LogicalKeyboardKey.arrowUp &&
      keyEvent.logicalKey != LogicalKeyboardKey.arrowDown) {
    return ExecutionInstruction.continueExecution;
  }

  return ExecutionInstruction.blocked;
}

// The SuperEditor defaults don't check from Meta-Shift combinations, so we
// bubble them early to override the default handlers.
ExecutionInstruction _bubbleOverrideKeys({
  required SuperEditorContext editContext,
  required KeyEvent keyEvent,
}) {
  if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
    return ExecutionInstruction.continueExecution;
  }

  // Bubble up meta key combos by blocking SuperEditor from handling them
  final isMetaPressed =
      (HardwareKeyboard.instance.isMetaPressed ||
          HardwareKeyboard.instance.isControlPressed) &&
      HardwareKeyboard.instance.isShiftPressed;
  if (isMetaPressed) {
    log.info(
      'Editor: Meta key combo detected - ${keyEvent.logicalKey.keyLabel} (bubbling to parent)',
    );
    return ExecutionInstruction.blocked;
  }

  return ExecutionInstruction.continueExecution;
}

ExecutionInstruction _bubbleSpecialKeys({
  required SuperEditorContext editContext,
  required KeyEvent keyEvent,
}) {
  if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
    return ExecutionInstruction.continueExecution;
  }

  if (keyEvent.logicalKey == LogicalKeyboardKey.escape) {
    return ExecutionInstruction.blocked;
  }

  // Bubble up meta key combos by blocking SuperEditor from handling them
  final isMetaPressed =
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isControlPressed;
  if (isMetaPressed) {
    log.info(
      'Editor: Meta key combo detected - ${keyEvent.logicalKey.keyLabel} (bubbling to parent)',
    );
    return ExecutionInstruction.blocked;
  }

  return ExecutionInstruction.continueExecution;
}

ExecutionInstruction _handlePunctuationAfterMention({
  required SuperEditorContext editContext,
  required KeyEvent keyEvent,
}) {
  if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
    return ExecutionInstruction.continueExecution;
  }

  // Check if this is a punctuation character
  final character = keyEvent.character;
  if (character == null || !['.', ',', ';'].contains(character)) {
    return ExecutionInstruction.continueExecution;
  }

  // Get current selection
  final selection = editContext.composer.selection;
  if (selection == null || !selection.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  // Get the current node
  final nodePosition = selection.extent.nodePosition;
  if (nodePosition is! TextNodePosition) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.document.getNodeById(selection.extent.nodeId);
  if (node is! TextNode) {
    return ExecutionInstruction.continueExecution;
  }

  final caretOffset = nodePosition.offset;

  // Check if there's a space before the caret
  if (caretOffset < 1) {
    return ExecutionInstruction.continueExecution;
  }

  final text = node.text.toPlainText();
  if (caretOffset > text.length || text[caretOffset - 1] != ' ') {
    return ExecutionInstruction.continueExecution;
  }

  // Check if the character before the space has a mention attribution
  if (caretOffset < 2) {
    return ExecutionInstruction.continueExecution;
  }

  final attributionsAtPrevChar = node.text.getAttributionSpansInRange(
    attributionFilter: (attr) => attr is CommittedEditorMentionAttribution,
    range: SpanRange(caretOffset - 2, caretOffset - 2),
  );

  if (attributionsAtPrevChar.isEmpty) {
    return ExecutionInstruction.continueExecution;
  }

  // Delete the space before inserting punctuation
  editContext.editor.execute([
    DeleteUpstreamCharacterRequest(),
    InsertCharacterAtCaretRequest(
      character: character,
      ignoreComposerAttributions: true,
    ),
  ]);

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction _handleBackspaceOverMention({
  required SuperEditorContext editContext,
  required KeyEvent keyEvent,
}) {
  if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
    return ExecutionInstruction.continueExecution;
  }

  if (keyEvent.logicalKey != LogicalKeyboardKey.backspace) {
    return ExecutionInstruction.continueExecution;
  }

  // Get current selection
  final selection = editContext.composer.selection;
  if (selection == null || !selection.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  // Get the current node
  final nodePosition = selection.extent.nodePosition;
  if (nodePosition is! TextNodePosition) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.document.getNodeById(selection.extent.nodeId);
  if (node is! TextNode) {
    return ExecutionInstruction.continueExecution;
  }

  final caretOffset = nodePosition.offset;

  // Check if we're at the start of the text (nothing to delete)
  if (caretOffset < 1) {
    return ExecutionInstruction.continueExecution;
  }

  // Check if the character before the caret has a mention attribution
  final attributionsAtPrevChar = node.text.getAttributionSpansInRange(
    attributionFilter: (attr) => attr is CommittedEditorMentionAttribution,
    range: SpanRange(caretOffset - 1, caretOffset - 1),
  );

  if (attributionsAtPrevChar.isEmpty) {
    return ExecutionInstruction.continueExecution;
  }

  // Found a mention - get its full span
  final mentionSpan = attributionsAtPrevChar.first;

  // Delete the entire mention span and update caret position
  editContext.editor.execute([
    DeleteContentRequest(
      documentRange: DocumentRange(
        start: DocumentPosition(
          nodeId: selection.extent.nodeId,
          nodePosition: TextNodePosition(offset: mentionSpan.start),
        ),
        end: DocumentPosition(
          nodeId: selection.extent.nodeId,
          nodePosition: TextNodePosition(offset: mentionSpan.end + 1),
        ),
      ),
    ),
    ChangeSelectionRequest(
      DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: selection.extent.nodeId,
          nodePosition: TextNodePosition(offset: mentionSpan.start),
        ),
      ),
      SelectionChangeType.placeCaret,
      SelectionReason.userInteraction,
    ),
  ]);

  return ExecutionInstruction.haltExecution;
}
