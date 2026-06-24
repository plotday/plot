import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:super_editor_spellcheck/super_editor_spellcheck.dart';
import 'package:flutter_debouncer/flutter_debouncer.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'code_block_component.dart';

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
import 'editor_clipboard.dart';
import 'editor_mention_plugin.dart';
import 'editor_mention_detector.dart';
import 'editor_mention_popover.dart';
import 'editor_link_detector.dart';
import 'editor_link_toolbar.dart';
import 'editor_link_modal.dart';
import 'editor_spelling_toolbar.dart';
import 'plot_image_component.dart';
import 'list_item_component.dart';
import 'task_component.dart';
import 'blockquote_component.dart';
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

  // Drop links whose visible text would be empty after the deserializer
  // extracts inline images into their own nodes — super_editor would warn
  // (`SpanRange(0, -1)`) and every other Markdown renderer shows them as
  // invisible/unclickable. Covers `[](url)`, `[ ](url)`, and
  // `[![alt](img)](url)` (html2md's form for `<a href="X"><img></a>`).
  processed = processed.replaceAll(
    RegExp(r'\[(?:\s*!\[[^\]]*\]\([^)]*\))*\s*\]\([^)]*\)'),
    '',
  );

  return processed;
}

/// Tokenise a search query into the minimum-length terms used for matching.
/// Mirrors the FTS preprocessing in `Note.watch`: split on whitespace, drop
/// FTS-special chars, then drop fragments shorter than 2 characters.
List<String> _searchHighlightTerms(String search) {
  final terms = <String>[];
  for (final raw in search.split(RegExp(r'\s+'))) {
    if (raw.isEmpty) continue;
    final cleaned = raw.replaceAll(RegExp(r'''['"*()/:+\-^~{}\[\]@#]'''), '');
    if (cleaned.length < 2) continue;
    terms.add(cleaned.toLowerCase());
  }
  return terms;
}

/// Add `searchHighlightAttribution` over every occurrence of any search
/// term in every text node of [document]. Matches are case-insensitive and
/// applied in place on each node's [AttributedText] so list/task/code nodes
/// keep their concrete type.
void _addSearchHighlightAttributions(MutableDocument document, String search) {
  final terms = _searchHighlightTerms(search);
  if (terms.isEmpty) return;

  for (int i = 0; i < document.nodeCount; i++) {
    final node = document.getNodeAt(i);
    if (node is! TextNode) continue;

    final text = node.text.toPlainText();
    if (text.isEmpty) continue;
    final lowered = text.toLowerCase();

    for (final term in terms) {
      int searchIndex = 0;
      while (true) {
        final index = lowered.indexOf(term, searchIndex);
        if (index == -1) break;
        node.text.addAttribution(
          searchHighlightAttribution,
          SpanRange(index, index + term.length - 1),
        );
        searchIndex = index + term.length;
      }
    }
  }
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

/// Extract language hints from fenced code blocks and attach to document nodes
void _attachCodeBlockLanguages(String markdown, MutableDocument document) {
  final langRegex = RegExp(r'^```(\w+)', multiLine: true);
  final languages = langRegex
      .allMatches(markdown)
      .map((m) => m.group(1)!)
      .toList();

  int langIndex = 0;
  for (int i = 0; i < document.nodeCount; i++) {
    final node = document.getNodeAt(i);
    if (node is! TextNode) continue;
    if (node.metadata['blockType'] != codeAttribution) continue;
    if (langIndex < languages.length) {
      final newMetadata = Map<String, dynamic>.from(node.metadata);
      newMetadata['language'] = languages[langIndex];
      document.replaceNodeById(
        node.id,
        ParagraphNode(id: node.id, text: node.text, metadata: newMetadata),
      );
    }
    langIndex++;
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

  // Attach language metadata to code blocks
  _attachCodeBlockLanguages(markdown, document);

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
    this.isInThread = false,
  });

  /// Create from a TwistInstance
  factory MentionItem.fromTwist(
    TwistInstance twist, {
    required List<TwistInstance> allInstances,
    String? teamName,
  }) => MentionItem(
    id: twist.id.toString(),
    name: twist.mentionLabel(allInstances: allInstances, teamName: teamName),
    isTwist: true,
  );

  /// Create from an Actor
  factory MentionItem.fromActor(Actor actor, {bool isInThread = false}) =>
      MentionItem(
        id: actor.id.toString(),
        name: actor.nameOrEmail,
        isInThread: isInThread,
      );

  final String id;
  final String name;
  final bool isTwist;

  /// Whether this person already participates in the current thread.
  /// Drives the suggestion ranking in the mention popover.
  final bool isInThread;
}

/// Inserts a newline inside a blockquote so that pressing Enter continues the
/// quote on a new line — matching list-item behavior — instead of dropping back
/// to a normal paragraph. Pressing Enter on an empty quote line exits the
/// blockquote (also mirroring how an empty list item converts to a paragraph).
///
/// SuperEditor's default newline handler only replicates a paragraph's
/// `blockType` metadata when the caret is *not* at the end of the line, so
/// continuing a quote (caret at end) would otherwise produce a plain paragraph.
class _InsertNewlineInBlockquoteAtCaretCommand
    extends BaseInsertNewlineAtCaretCommand {
  const _InsertNewlineInBlockquoteAtCaretCommand(this.newNodeId);

  final String newNodeId;

  @override
  void doInsertNewline(
    EditContext context,
    CommandExecutor executor,
    DocumentPosition caretPosition,
    NodePosition caretNodePosition,
  ) {
    final node = context.document.getNodeById(caretPosition.nodeId);
    if (caretNodePosition is! TextNodePosition || node is! ParagraphNode) {
      return;
    }

    if (node.text.isEmpty) {
      // Empty quote line: exit the blockquote by converting it to a paragraph.
      executor.executeCommand(
        ChangeParagraphBlockTypeCommand(
          nodeId: node.id,
          blockType: paragraphAttribution,
        ),
      );
      return;
    }

    // Split the quote, keeping the blockquote metadata on the new line so the
    // quote continues.
    executor
      ..executeCommand(
        SplitParagraphCommand(
          nodeId: node.id,
          splitPosition: caretNodePosition,
          newNodeId: newNodeId,
          replicateExistingMetadata: true,
        ),
      )
      ..executeCommand(
        ChangeSelectionCommand(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: newNodeId,
              nodePosition: const TextNodePosition(offset: 0),
            ),
          ),
          SelectionChangeType.insertContent,
          SelectionReason.userInteraction,
        ),
      );
  }
}

class Editor extends StatefulWidget {
  const Editor({
    this.hint,
    this.autofocus = false,
    this.onSubmitted,
    this.onChange,
    this.onIsEmptyChanged,
    this.onImagePasted,
    this.onUrlPastedWhenEmpty,
    this.onTwistMentioned,
    this.focusNode,
    this.twists = const [],
    this.actors = const [],
    this.threadContactIds = const <String>{},
    this.shrinkWrap = true,
    this.initialContent,
    super.key,
  });

  final String? hint;
  final bool autofocus;
  final void Function(String value, {bool alt})? onSubmitted;
  final ValueChanged<String>? onChange;
  final ValueChanged<bool>? onIsEmptyChanged;

  /// Called when an image is pasted from the clipboard.
  /// The callback receives the raw image bytes (PNG format).
  final void Function(Uint8List imageBytes)? onImagePasted;

  /// Called when a plain-text URL is pasted into an otherwise empty editor.
  /// When set and invoked, the URL is NOT inserted into the editor body —
  /// the host is expected to attach it as a link (e.g. as an action row).
  final void Function(String url)? onUrlPastedWhenEmpty;

  /// Fires when the user completes an @-mention of a twist from the
  /// suggestion popover. The receiver should treat the selection as a
  /// connection-target pick (parallel to how contact mentions add the
  /// person to the thread). The mention text is still inserted in the
  /// body — this is an additive signal.
  final void Function(String twistId)? onTwistMentioned;
  final FocusNode? focusNode;
  final List<TwistInstance> twists;
  final List<Actor> actors;

  /// Actor IDs (as strings) of contacts currently associated with the thread
  /// where this editor is composing. Used to rank in-thread contacts ahead of
  /// twists and other contacts in the @-mention suggestions.
  final Set<String> threadContactIds;
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

  // SuperEditor requires a unique inputRole per concurrently-mounted editor,
  // otherwise its debug-mode duplicate-input check throws (e.g. during route
  // transitions or in multi-panel layouts where two editors coexist briefly).
  static int _nextInputRoleId = 0;
  final String _inputRole = 'plot-note-editor-${_nextInputRoleId++}';

  final GlobalKey _docLayoutKey = GlobalKey();
  late FocusNode _editorFocusNode;
  late ScrollController _scrollController;
  late MutableDocument _document;
  late MutableDocumentComposer _composer;
  late super_editor.Editor _editor;
  final Debouncer _debouncer = Debouncer();
  bool _isEmpty = true;

  /// Guards against double-paste when both the hardware Cmd+V keyboard
  /// action and the macOS `paste:` selector arrive for the same Cmd+V.
  DateTime? _lastSmartPasteAt;

  // Snapshot-based undo/redo (SuperEditor's replay-based undo is broken)
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];
  String? _lastSnapshot;
  bool _isRestoringSnapshot = false;
  static const _maxUndoHistory = 100;

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

  // Spellcheck (macOS native, iOS/Android via Flutter's DefaultSpellCheckService;
  // Windows/Linux/Web are unsupported by super_editor_spellcheck and skipped).
  SuperEditorAndroidControlsController? _androidControlsController;
  SuperEditorIosControlsController? _iosControlsController;
  SpellingAndGrammarPlugin? _spellingPlugin;
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

  /// Returns the appropriate input source based on the current platform.
  ///
  /// macOS uses IME so that:
  /// - The Character Viewer (Ctrl+Cmd+Space) and other system-level text
  ///   inputs reach the editor via `NSTextInputClient.insertText:`.
  /// - System actions like `paste:` (triggered by Cmd+V, including when
  ///   synthesized by tools like Raycast that don't reliably propagate the
  ///   Cmd modifier to Flutter's HardwareKeyboard) are dispatched through
  ///   selectors, which we handle below.
  TextInputSource get _inputSource {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return TextInputSource.ime;
      default:
        return TextInputSource.keyboard;
    }
  }

  void clear() {
    setState(() {
      _editor.execute([ClearDocumentRequest()]);
      _undoStack.clear();
      _redoStack.clear();
      _lastSnapshot = _serializeWithMentions(_document);
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
          requests.add(
            InsertNodeAtIndexRequest(nodeIndex: index++, newNode: node),
          );
        }
      } else {
        requests.add(ClearDocumentRequest());
      }

      _editor.execute(requests);

      // Update isEmpty state
      _isEmpty = serializeDocumentToMarkdown(_document).isEmpty;

      _undoStack.clear();
      _redoStack.clear();
      _lastSnapshot = _serializeWithMentions(_document);
    });
  }

  /// Focuses the editor and moves the caret to the end of the document. Used
  /// when an un-sent note is restored into the composer (Esc / undo send) so
  /// focus stays on the editor with the cursor after the restored text.
  void placeCaretAtEnd() {
    final lastNode = _document.getNodeAt(_document.nodeCount - 1);
    if (lastNode != null) {
      _editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: lastNode.id,
              nodePosition: lastNode.endPosition,
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    }
    _editorFocusNode.requestFocus();
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
    // Capture undo snapshot: push the previous state onto the undo stack
    // when a real edit occurs (skip if we're restoring from a snapshot).
    if (!_isRestoringSnapshot && _lastSnapshot != null) {
      final hasContentChange = changeList.any((e) => e is DocumentEdit);
      if (hasContentChange) {
        _undoStack.add(_lastSnapshot!);
        if (_undoStack.length > _maxUndoHistory) {
          _undoStack.removeAt(0);
        }
        _redoStack.clear();
      }
    }

    final isEmpty = serializeDocumentToMarkdown(_document).isEmpty;
    setState(() {
      _isEmpty = isEmpty;
    });
    // Notify parent immediately for instant UI updates
    widget.onIsEmptyChanged?.call(isEmpty);

    // Update snapshot to current state
    if (!_isRestoringSnapshot) {
      _lastSnapshot = _serializeWithMentions(_document);
    }
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
    );
    // Make Enter continue a blockquote (like list items) rather than dropping
    // back to a plain paragraph. Inserted before the default newline handler so
    // it wins for blockquote nodes; returns null (falls through) for everything
    // else.
    _editor.requestHandlers.insert(0, (editor, request) {
      if (request is! InsertNewlineAtCaretRequest) return null;
      final selection = editor.composer.selection;
      if (selection == null) return null;
      final node = editor.document.getNodeById(selection.base.nodeId);
      if (node is! ParagraphNode ||
          node.metadata[NodeMetadata.blockType] != blockquoteAttribution) {
        return null;
      }
      return _InsertNewlineInBlockquoteAtCaretCommand(request.newNodeId);
    });
    _editor.addListener(_documentChangeListener);
    _lastSnapshot = _serializeWithMentions(_document);
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

    _initSpellcheck();

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
            requests.add(
              InsertNodeAtIndexRequest(nodeIndex: index++, newNode: node),
            );
          }

          _editor.execute(requests);
        });

        // The spell-check reaction only watches NodeChangeEvents (text edits)
        // and ignores NodeInsertedEvents, so the bulk insert above doesn't
        // trigger a spell check on the freshly-loaded draft. Re-run analysis.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _refreshSpellcheckReaction();
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
    _androidControlsController?.dispose();
    _iosControlsController?.dispose();
    super.dispose();
  }

  /// Construct the spellcheck plugin and platform controllers.
  /// macOS gets native NSSpellChecker (spell + grammar). iOS/Android use
  /// Flutter's DefaultSpellCheckService (spell only). Web/Windows/Linux skip.
  void _initSpellcheck() {
    if (kIsWeb) return;
    final platform = defaultTargetPlatform;
    final supported =
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.android;
    if (!supported) return;

    if (platform == TargetPlatform.android) {
      _androidControlsController = SuperEditorAndroidControlsController();
    } else if (platform == TargetPlatform.iOS) {
      _iosControlsController = SuperEditorIosControlsController();
    }

    _spellingPlugin = SpellingAndGrammarPlugin(
      androidControlsController: _androidControlsController,
      iosControlsController: _iosControlsController,
      spellCheckDelayAfterEdit: const Duration(milliseconds: 500),
      toolbarBuilder: editorSpellingToolbarBuilder,
      ignoreRules: [
        SpellingIgnoreRules.byAttributionFilter((a) => a is LinkAttribution),
        SpellingIgnoreRules.byAttributionFilter(
          (a) => a is CommittedEditorMentionAttribution,
        ),
        SpellingIgnoreRules.byAttributionFilter(
          (a) => a == editorMentionComposingAttribution,
        ),
      ],
    );
    // The constructor captures spellingErrorUnderlineStyle but never forwards
    // it to the styler — only the setter does. Apply via setter.
    _spellingPlugin!.spellingErrorUnderlineStyle = const SquiggleUnderlineStyle(
      color: Color(0x99E54B4B),
      thickness: 1,
      jaggedDeltaY: 1.5,
    );

    // Grammar: same constructor bug — `isGrammarCheckEnabled: false` doesn't
    // propagate to the reaction (which defaults to true). The reaction is
    // created during the plugin's attach() on first SuperEditor build, so
    // toggle it on the next frame. Same hook re-analyzes the document for
    // the case where content arrived via didUpdateWidget after attach: the
    // reaction only watches NodeChangeEvents and skips bulk node inserts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshSpellcheckReaction(disableGrammar: true);
    });
  }

  /// Walk the editor's reaction pipeline to find our spell/grammar reaction
  /// and (optionally) disable grammar, then trigger a whole-document analysis.
  void _refreshSpellcheckReaction({bool disableGrammar = false}) {
    final reaction = _editor.reactionPipeline
        .whereType<SpellingAndGrammarReaction>()
        .firstOrNull;
    if (reaction == null) return;
    if (disableGrammar) reaction.isGrammarCheckEnabled = false;
    reaction.analyzeWholeDocument(_editor.context);
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
              child: _wrapWithControlsScopes(
                SuperEditor(
                  inputRole: _inputRole,
                  autofocus: widget.autofocus,
                  editor: _editor,
                  focusNode: _editorFocusNode,
                  shrinkWrap: widget.shrinkWrap,
                  scrollController: _scrollController,
                  documentLayoutKey: _docLayoutKey,
                  inputSource: _inputSource,
                  gestureMode: _gestureMode,
                  plugins: {?_spellingPlugin},
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
                    const PlotImageComponentBuilder(),
                    const PlotListItemComponentBuilder(),
                    const PlotBlockquoteComponentBuilder(),
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
                    _handleUndoKeyPress,
                    _handleRedoKeyPress,
                    // Use IME keyboard actions on mobile, regular keyboard actions on desktop
                    // (SuperEditor's built-in undo/redo are superseded by our handlers above)
                    ...(_inputSource == TextInputSource.ime
                        ? defaultImeKeyboardActions
                        : defaultKeyboardActions),
                    _bubbleSpecialKeys, // Process meta key combos first to allow propagation
                  ],
                  selectorHandlers: {
                    ...defaultEditorSelectorHandlers,
                    // macOS `paste:` selector — fires for Cmd+V via the IME,
                    // including synthetic events (e.g. Raycast emoji picker)
                    // whose Cmd modifier doesn't reach HardwareKeyboard.
                    'paste:': _handlePasteSelector,
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrapWithControlsScopes(Widget child) {
    Widget result = child;
    if (_iosControlsController != null) {
      result = SuperEditorIosControlsScope(
        controller: _iosControlsController!,
        child: result,
      );
    }
    if (_androidControlsController != null) {
      result = SuperEditorAndroidControlsScope(
        controller: _androidControlsController!,
        child: result,
      );
    }
    return result;
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
    _writeSelectionToClipboard();
    _commonOps.deleteSelection(TextAffinity.downstream);
    _editorFocusNode.requestFocus();
  }

  void performCopy() {
    _writeSelectionToClipboard();
    _editorFocusNode.requestFocus();
  }

  void performPaste() {
    _commonOps.paste();
    _editorFocusNode.requestFocus();
  }

  /// Serialize the current selection to multi-format clipboard data:
  /// Plot markdown (lossless), HTML, and plain text.
  void _writeSelectionToClipboard() {
    final selection = _composer.selection;
    if (selection == null) return;

    // Get markdown for the selected range (with link attributions preserved)
    final plotMarkdown = _serializeSelectionWithMentions(selection);

    // Plain text: strip all markdown formatting
    final plainText = markdownToPlainText(plotMarkdown);

    // HTML: convert markdown to HTML (with mention syntax stripped)
    final html = markdownToHtml(plotMarkdown);

    writeClipboard(
      plotMarkdown: plotMarkdown,
      plainText: plainText,
      html: html,
    );
  }

  /// Serialize a document selection to markdown with mentions.
  /// Like [_serializeWithMentions] but scoped to the given selection.
  String _serializeSelectionWithMentions(DocumentSelection selection) {
    String markdown = serializeDocumentToMarkdown(
      _document,
      selection: selection,
    );

    // Get the selected nodes to find mention attributions
    final normalizedSelection = selection.normalize(_document);
    final selectedNodes = _document.getNodesInside(
      normalizedSelection.start,
      normalizedSelection.end,
    );

    for (final node in selectedNodes) {
      if (node is! TextNode) continue;

      final text = node.text;
      if (text.length == 0) continue;

      final spans = text.getAttributionSpansInRange(
        attributionFilter: (attr) => attr is CommittedEditorMentionAttribution,
        range: SpanRange(0, text.length - 1),
      );

      final spansList = spans.toList()
        ..sort((a, b) => b.start.compareTo(a.start));

      for (final span in spansList) {
        final attribution =
            span.attribution as CommittedEditorMentionAttribution;
        final mentionText = text.substring(span.start, span.end + 1);
        final name = attribution.username;
        final replacement = '[$name](#@${attribution.actorId})';
        markdown = markdown.replaceFirst(mentionText, replacement);
      }
    }

    return markdown;
  }

  void performSelectAll() {
    _commonOps.selectAll();
    _editorFocusNode.requestFocus();
  }

  void performUndo() {
    if (_undoStack.isEmpty) return;
    final currentMd = _serializeWithMentions(_document);
    _redoStack.add(currentMd);
    final previousMd = _undoStack.removeLast();
    _restoreFromSnapshot(previousMd);
    _editorFocusNode.requestFocus();
  }

  void performRedo() {
    if (_redoStack.isEmpty) return;
    final currentMd = _serializeWithMentions(_document);
    _undoStack.add(currentMd);
    final nextMd = _redoStack.removeLast();
    _restoreFromSnapshot(nextMd);
    _editorFocusNode.requestFocus();
  }

  /// Restore the document from a markdown snapshot.
  void _restoreFromSnapshot(String markdown) {
    _isRestoringSnapshot = true;
    final newDocument = _deserializeMarkdownWithMentions(markdown);

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

    // Insert all nodes from the snapshot document
    int index = 0;
    for (final node in newDocument.toList()) {
      requests.add(InsertNodeAtIndexRequest(nodeIndex: index++, newNode: node));
    }

    _editor.execute(requests);

    // Place caret at end of document
    final lastNode = _document.getNodeAt(_document.nodeCount - 1);
    if (lastNode is TextNode) {
      _editor.execute([
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: lastNode.id,
              nodePosition: TextNodePosition(offset: lastNode.text.length),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.contentChange,
        ),
      ]);
    }

    _lastSnapshot = markdown;
    _isRestoringSnapshot = false;
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

  /// Build the combined mention items list from twists and actors.
  ///
  /// Connectors (source twists) are excluded entirely — only true twists are
  /// surfaced. Contacts that already participate in the thread are flagged so
  /// the popover can rank them first.
  List<MentionItem> _buildMentionItems() {
    final mentionableTwists = widget.twists.where((t) => !t.isSource);
    final twistActorIds = mentionableTwists.map((t) => t.id.toString()).toSet();
    final threadContactIds = widget.threadContactIds;
    return [
      ...mentionableTwists.map(
        (twist) => MentionItem.fromTwist(
          twist,
          allInstances: widget.twists,
          teamName: null,
        ),
      ),
      ...widget.actors
          .where((actor) => !twistActorIds.contains(actor.id.toString()))
          .map(
            (actor) => MentionItem.fromActor(
              actor,
              isInThread: threadContactIds.contains(actor.id.toString()),
            ),
          ),
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

    // Group order: in-thread people → twists → other people.
    // MRU sorting is applied within each group so frequently-mentioned items
    // surface first inside their tier. "People" covers both external contacts
    // and Plot users — the `user.actor` view types contacts linked to a user
    // account as `user`, so a contact-only filter would drop every Plot user.
    final localPrefs = context.read<LocalPreferencesBloc>();
    final inThreadContacts = mentionItems
        .where((item) => !item.isTwist && item.isInThread)
        .toList();
    final twists = mentionItems.where((item) => item.isTwist).toList();
    final otherContacts = mentionItems
        .where((item) => !item.isTwist && !item.isInThread)
        .toList();
    final sortedItems = [
      ...localPrefs.sortByMentionMru(inThreadContacts, (item) => item.id),
      ...localPrefs.sortByMentionMru(twists, (item) => item.id),
      ...localPrefs.sortByMentionMru(otherContacts, (item) => item.id),
    ];

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

        if (item.isTwist) {
          widget.onTwistMentioned?.call(item.id);
        }

        // Notify immediately so thread sharing chips update without debounce delay
        notify();
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

  /// Keyboard action: Undo via Cmd+Z / Ctrl+Z using markdown snapshots.
  ExecutionInstruction _handleUndoKeyPress({
    required SuperEditorContext editContext,
    required KeyEvent keyEvent,
  }) {
    if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
      return ExecutionInstruction.continueExecution;
    }
    if (keyEvent.logicalKey != LogicalKeyboardKey.keyZ ||
        !keyEvent.isPrimaryShortcutKeyPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return ExecutionInstruction.continueExecution;
    }
    performUndo();
    return ExecutionInstruction.haltExecution;
  }

  /// Keyboard action: Redo via Cmd+Shift+Z / Ctrl+Shift+Z using markdown snapshots.
  ExecutionInstruction _handleRedoKeyPress({
    required SuperEditorContext editContext,
    required KeyEvent keyEvent,
  }) {
    if (keyEvent is! KeyDownEvent && keyEvent is! KeyRepeatEvent) {
      return ExecutionInstruction.continueExecution;
    }
    if (keyEvent.logicalKey != LogicalKeyboardKey.keyZ ||
        !keyEvent.isPrimaryShortcutKeyPressed ||
        !HardwareKeyboard.instance.isShiftPressed) {
      return ExecutionInstruction.continueExecution;
    }
    performRedo();
    return ExecutionInstruction.haltExecution;
  }

  /// Keyboard action: Smart paste - reads multi-format clipboard via
  /// super_clipboard with priority: image → Plot markdown → HTML → URL → text.
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

    _triggerSmartPaste(selection);
    return ExecutionInstruction.haltExecution;
  }

  /// Selector handler for macOS `paste:`. Fires when the OS dispatches Cmd+V
  /// (or any synthesized paste action, e.g. from Raycast's CGEventPost) via
  /// `NSTextInputClient`. This path doesn't depend on Flutter's
  /// HardwareKeyboard modifier tracking, so it works for synthetic events
  /// where the Cmd flag isn't reflected in `isMetaPressed`.
  void _handlePasteSelector(SuperEditorContext editContext) {
    final selection = editContext.composer.selection;
    if (selection == null) return;
    _triggerSmartPaste(selection);
  }

  /// Schedule a smart paste, deduplicating against same-tick hardware/selector
  /// dispatches for the same Cmd+V. On macOS in IME mode both the hardware
  /// key handler and the `paste:` selector fire for a real Cmd+V; synthesized
  /// events from tools like Raycast only reach the selector path.
  void _triggerSmartPaste(DocumentSelection selection) {
    final now = DateTime.now();
    if (_lastSmartPasteAt != null &&
        now.difference(_lastSmartPasteAt!).inMilliseconds < 200) {
      return;
    }
    _lastSmartPasteAt = now;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _readClipboardAndPaste(selection);
    });
  }

  /// Read clipboard using super_clipboard and paste with format priority.
  Future<void> _readClipboardAndPaste(DocumentSelection selection) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      _normalPaste();
      return;
    }
    final reader = await clipboard.read();

    // 1. Check for image → upload as file attachment
    if (widget.onImagePasted != null && reader.canProvide(Formats.png)) {
      final imageBytes = await _readFileBytes(reader, Formats.png);
      if (imageBytes != null && imageBytes.isNotEmpty) {
        widget.onImagePasted!(imageBytes);
        return;
      }
    }

    // 2. Check for Plot markdown → lossless intra-app paste
    if (reader.canProvide(plotMarkdownFormat)) {
      final bytes = await reader.readValue<Uint8List>(plotMarkdownFormat);
      if (bytes != null) {
        final markdown = utf8.decode(bytes);
        if (markdown.isNotEmpty) {
          _pasteMarkdownContent(markdown);
          return;
        }
      }
    }

    // 3. Check for HTML → convert to markdown and paste as rich content
    if (reader.canProvide(Formats.htmlText)) {
      final html = await reader.readValue<String>(Formats.htmlText);
      if (html != null && html.isNotEmpty) {
        final markdown = htmlToMarkdown(html);
        if (markdown.trim().isNotEmpty) {
          _pasteMarkdownContent(markdown);
          return;
        }
      }
    }

    // 4. Check for plain text
    final plainText = await reader.readValue<String>(Formats.plainText);
    final text = plainText?.trim();

    if (text == null || text.isEmpty) return;

    // 4a. If text is a URL and text is selected, apply as link attribution
    if (!selection.isCollapsed && _isUrl(text)) {
      final currentSelection = _composer.selection;
      if (currentSelection != null && !currentSelection.isCollapsed) {
        _editor.execute([
          AddTextAttributionsRequest(
            documentRange: currentSelection,
            attributions: {LinkAttribution(text)},
          ),
        ]);
        return;
      }
    }

    // 4b. If text is a URL (collapsed cursor), insert with title resolution.
    // When the editor is otherwise empty and the host opts in, hand the URL
    // off to be attached as a link instead of inserting it into the body.
    if (selection.isCollapsed && _isUrl(text)) {
      if (_isEmpty && widget.onUrlPastedWhenEmpty != null) {
        widget.onUrlPastedWhenEmpty!(text);
        return;
      }
      _pasteUrlWithTitleResolution(text);
      return;
    }

    // 5. Fall through to normal plain text paste
    _normalPaste();
  }

  /// Paste markdown content at the current cursor position.
  /// Parses the markdown into a document, then inserts the nodes.
  void _pasteMarkdownContent(String markdown) {
    final parsedDoc = _deserializeMarkdownWithMentions(markdown);
    var parsedNodes = parsedDoc.toList();
    if (parsedNodes.isEmpty) return;

    // Drop empty paragraphs so paragraph breaks are preserved but blank
    // lines between paragraphs are not pasted as visible gaps.
    parsedNodes = parsedNodes
        .where(
          (n) => n is! ParagraphNode || n.text.toPlainText().trim().isNotEmpty,
        )
        .toList();
    if (parsedNodes.isEmpty) return;

    // When pasting into a blockquote, keep the whole pasted content inside
    // the quote: stamp blockquote metadata onto every text-bearing node so
    // subsequent paragraphs stay quoted instead of breaking out of the block.
    // Lists and tasks are flattened into blockquote paragraphs because
    // super_editor's data model has no concept of a list nested inside a
    // blockquote — each node is a sibling at the document root.
    final selectionNodeId = _composer.selection?.extent.nodeId;
    final cursorNodeNow = selectionNodeId != null
        ? _document.getNodeById(selectionNodeId)
        : null;
    final pastingIntoBlockquote =
        cursorNodeNow is ParagraphNode &&
        cursorNodeNow.getMetadataValue('blockType') == blockquoteAttribution;
    if (pastingIntoBlockquote) {
      parsedNodes = parsedNodes.map((n) {
        if (n is ParagraphNode) {
          return n.copyParagraphWith(
            metadata: {...n.metadata, 'blockType': blockquoteAttribution},
          );
        }
        if (n is TextNode) {
          return ParagraphNode(
            id: n.id,
            text: n.text,
            metadata: const {'blockType': blockquoteAttribution},
          );
        }
        return n;
      }).toList();
    }

    // Delete any selected content first
    if (_composer.selection != null && !_composer.selection!.isCollapsed) {
      final pastePosition =
          CommonEditorOperations.getDocumentPositionAfterExpandedDeletion(
            document: _document,
            selection: _composer.selection!,
          );
      if (pastePosition == null) return;

      _editor.execute([
        DeleteContentRequest(documentRange: _composer.selection!),
        ChangeSelectionRequest(
          DocumentSelection.collapsed(position: pastePosition),
          SelectionChangeType.deleteContent,
          SelectionReason.userInteraction,
        ),
      ]);
    }

    final insertPosition = _composer.selection?.extent;
    if (insertPosition == null) return;

    // Single paragraph: insert inline with attributions at cursor
    if (parsedNodes.length == 1 && parsedNodes.first is TextNode) {
      final sourceNode = parsedNodes.first as TextNode;
      final sourceText = sourceNode.text;
      final plainText = sourceText.toPlainText();
      if (plainText.isEmpty) return;

      // Insert the plain text
      _editor.execute([
        InsertTextRequest(
          documentPosition: insertPosition,
          textToInsert: plainText,
          attributions: {},
        ),
      ]);

      // Apply attributions from the parsed text
      final insertOffset =
          (insertPosition.nodePosition as TextNodePosition).offset;
      final allSpans = sourceText.getAttributionSpansInRange(
        attributionFilter: (attr) => true,
        range: SpanRange(0, sourceText.length - 1),
      );
      for (final span in allSpans) {
        _editor.execute([
          AddTextAttributionsRequest(
            documentRange: DocumentRange(
              start: DocumentPosition(
                nodeId: insertPosition.nodeId,
                nodePosition: TextNodePosition(
                  offset: insertOffset + span.start,
                ),
              ),
              end: DocumentPosition(
                nodeId: insertPosition.nodeId,
                nodePosition: TextNodePosition(
                  offset: insertOffset + span.end + 1,
                ),
              ),
            ),
            attributions: {span.attribution},
          ),
        ]);
      }
      return;
    }

    // Multi-paragraph: insert as new document nodes
    // Split the current paragraph at cursor, then insert between
    final cursorNode = _document.getNodeById(insertPosition.nodeId);
    if (cursorNode == null) return;
    final cursorNodeIndex = _document.getNodeIndexById(insertPosition.nodeId);

    final requests = <EditRequest>[];

    if (cursorNode is TextNode) {
      final offset = (insertPosition.nodePosition as TextNodePosition).offset;
      final existingText = cursorNode.text;

      // Text after cursor that will be moved to a new trailing paragraph
      final afterText = existingText.length > offset
          ? existingText.copyText(offset)
          : AttributedText('');

      // Only merge when both sides are plain paragraphs. ListItemNode and
      // TaskNode also extend TextNode but represent block structure; merging
      // their text into the cursor's paragraph would silently drop the
      // bullet/checkbox of the first pasted item.
      final firstParsed = parsedNodes.first;
      final canMergeFirst =
          cursorNode.runtimeType == ParagraphNode &&
          firstParsed.runtimeType == ParagraphNode;
      if (canMergeFirst && firstParsed is TextNode) {
        // Delete text after cursor from current node
        if (existingText.length > offset) {
          requests.add(
            DeleteContentRequest(
              documentRange: DocumentRange(
                start: DocumentPosition(
                  nodeId: cursorNode.id,
                  nodePosition: TextNodePosition(offset: offset),
                ),
                end: DocumentPosition(
                  nodeId: cursorNode.id,
                  nodePosition: TextNodePosition(offset: existingText.length),
                ),
              ),
            ),
          );
        }

        // Append the first parsed node's text to current node
        final firstText = firstParsed.text;
        if (firstText.toPlainText().isNotEmpty) {
          requests.add(
            InsertTextRequest(
              documentPosition: DocumentPosition(
                nodeId: cursorNode.id,
                nodePosition: TextNodePosition(offset: offset),
              ),
              textToInsert: firstText.toPlainText(),
              attributions: {},
            ),
          );

          // Apply attributions from the first parsed node
          final firstSpans = firstText.getAttributionSpansInRange(
            attributionFilter: (attr) => true,
            range: SpanRange(0, firstText.length - 1),
          );
          for (final span in firstSpans) {
            requests.add(
              AddTextAttributionsRequest(
                documentRange: DocumentRange(
                  start: DocumentPosition(
                    nodeId: cursorNode.id,
                    nodePosition: TextNodePosition(offset: offset + span.start),
                  ),
                  end: DocumentPosition(
                    nodeId: cursorNode.id,
                    nodePosition: TextNodePosition(
                      offset: offset + span.end + 1,
                    ),
                  ),
                ),
                attributions: {span.attribution},
              ),
            );
          }
        }
      }

      // When the first parsed node was not merged, the existing text after
      // the cursor must still be split off into a trailing paragraph.
      if (!canMergeFirst && existingText.length > offset) {
        requests.add(
          DeleteContentRequest(
            documentRange: DocumentRange(
              start: DocumentPosition(
                nodeId: cursorNode.id,
                nodePosition: TextNodePosition(offset: offset),
              ),
              end: DocumentPosition(
                nodeId: cursorNode.id,
                nodePosition: TextNodePosition(offset: existingText.length),
              ),
            ),
          ),
        );
      }

      // Insert remaining parsed nodes as new document nodes (skip the first
      // one only when it was merged into the cursor paragraph).
      var insertIndex = cursorNodeIndex + 1;
      final firstUnmergedIndex = canMergeFirst ? 1 : 0;
      for (int i = firstUnmergedIndex; i < parsedNodes.length; i++) {
        requests.add(
          InsertNodeAtIndexRequest(
            nodeIndex: insertIndex++,
            newNode: parsedNodes[i],
          ),
        );
      }

      // Add trailing paragraph with text after cursor (if any)
      if (afterText.toPlainText().isNotEmpty) {
        requests.add(
          InsertNodeAtIndexRequest(
            nodeIndex: insertIndex,
            newNode: ParagraphNode(
              id: super_editor.Editor.createNodeId(),
              text: afterText,
            ),
          ),
        );
      }

      // If the cursor was in an empty paragraph and we inserted structural
      // content instead of merging, drop the now-empty cursor paragraph so
      // the paste doesn't leave a stray blank line above it.
      if (!canMergeFirst &&
          existingText.length == 0 &&
          cursorNode is ParagraphNode) {
        requests.add(DeleteNodeRequest(nodeId: cursorNode.id));
      }
    } else {
      // Non-text node: just insert all parsed nodes after current
      var insertIndex = cursorNodeIndex + 1;
      for (final node in parsedNodes) {
        requests.add(
          InsertNodeAtIndexRequest(nodeIndex: insertIndex++, newNode: node),
        );
      }
    }

    // Place the cursor at the end of the last pasted node so subsequent
    // typing continues from where the paste ended (rather than wherever the
    // selection happened to land after the structural edits).
    final lastPasted = parsedNodes.last;
    final NodePosition lastPosition;
    if (lastPasted is TextNode) {
      lastPosition = TextNodePosition(offset: lastPasted.text.length);
    } else {
      lastPosition = const UpstreamDownstreamNodePosition.downstream();
    }
    requests.add(
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: lastPasted.id,
            nodePosition: lastPosition,
          ),
        ),
        SelectionChangeType.insertContent,
        SelectionReason.userInteraction,
      ),
    );

    if (requests.isNotEmpty) {
      _editor.execute(requests);
    }
  }

  /// Insert a URL at cursor and asynchronously resolve its page title.
  void _pasteUrlWithTitleResolution(String text) {
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
    () async {
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

      if (mounted && title != null) {
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
      }
    }();
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

  /// Read binary file bytes from a clipboard reader for a given file format.
  Future<Uint8List?> _readFileBytes(
    ClipboardReader reader,
    FileFormat format,
  ) async {
    final completer = Completer<Uint8List?>();
    final progress = reader.getFile(format, (file) async {
      try {
        final allBytes = <int>[];
        await for (final chunk in file.getStream()) {
          allBytes.addAll(chunk);
        }
        completer.complete(Uint8List.fromList(allBytes));
      } catch (_) {
        completer.complete(null);
      }
    }, onError: (_) => completer.complete(null));
    if (progress == null) return null;
    return completer.future;
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
  Viewer({required this.markdown, this.searchHighlight, super.key})
    : document = deserializeMarkdownToDocument(_preprocessMarkdown(markdown));

  final String markdown;
  final String? searchHighlight;
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
    final document = _deserializeMarkdownWithMentions(widget.markdown);
    final highlight = widget.searchHighlight;
    if (highlight != null && highlight.isNotEmpty) {
      _addSearchHighlightAttributions(document, highlight);
    }
    return document;
  }

  @override
  void didUpdateWidget(Viewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebuild the document when markdown or the active search term changes.
    if (oldWidget.markdown != widget.markdown ||
        oldWidget.searchHighlight != widget.searchHighlight) {
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
    // Wrap in SingleChildScrollView to prevent SuperReader's internal
    // DocumentScrollable from finding the ancestor reversed CustomScrollView.
    // Without this, auto-scroll during text selection drag goes in the wrong
    // direction because the ancestor list is reversed.
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: BoxToSliverAdapter(
        child: SuperReader(
          editor: _editor,
          stylesheet: _buildStylesheet(context, isDark),
          // selection: _selection,
          selectionLayerLinks: _selectionLayerLinks,
          selectionStyle: SelectionStyles(
            selectionColor: context.theme.colors.primaryForeground,
          ),
          componentBuilders: <ComponentBuilder>[
            const PlotBlockquoteComponentBuilder(),
            const PlotCodeBlockComponentBuilder(),
            const MarkdownTableComponentBuilder(fit: TableComponentFit.scroll),
            const ParagraphComponentBuilder(),
            const PlotListItemComponentBuilder(),
            const PlotImageComponentBuilder(),
            const HorizontalRuleComponentBuilder(),
            PlotTaskComponentBuilder(_editor),
          ],
          contentTapDelegateFactory: (readerContext) =>
              ViewerTapHandler(readerContext.document, context: context),
        ),
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
    // Links follow the thread's own priority accent (context.colour), with a
    // teal fallback for the near-invisible gray theme 7 — see
    // ColourSchemeData.linkColor. Deriving from context.colour (not
    // context.theme.colors.primary) keeps links visible in the Everything feed,
    // where the focus theme is gray while a thread keeps its own colour.
    style = style.copyWith(
      color: context.colour.linkColor,
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

  // Search-term highlight: yellow background tinted to the active theme so
  // matches stand out without overriding link/mention text colours.
  if (attributions.contains(searchHighlightAttribution)) {
    style = style.copyWith(
      backgroundColor: isDark
          ? const Color(0xFF7A5A00)
          : const Color(0xFFFFF1A8),
    );
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
      // Headings — conservative sizing so they stand out within a thread
      // without overwhelming the surrounding prose. Sizes scale off the base
      // body size; bottom padding is intentionally 0 so the default block
      // top padding (`spacing.md`) is the only gap before the following
      // block, keeping heading + content visually grouped.
      StyleRule(const BlockSelector("header1"), (doc, docNode) {
        return {
          Styles.textStyle: baseStyle.copyWith(
            fontSize: (baseStyle.fontSize ?? 15) * 1.25,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          Styles.padding: CascadingPadding.only(top: spacing.xl),
        };
      }),
      StyleRule(const BlockSelector("header2"), (doc, docNode) {
        return {
          Styles.textStyle: baseStyle.copyWith(
            fontSize: (baseStyle.fontSize ?? 15) * 1.12,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          Styles.padding: CascadingPadding.only(top: spacing.lg),
        };
      }),
      StyleRule(const BlockSelector("header3"), (doc, docNode) {
        return {
          Styles.textStyle: baseStyle.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.35,
          ),
          Styles.padding: CascadingPadding.only(top: spacing.lg),
        };
      }),
      StyleRule(const BlockSelector("header4"), (doc, docNode) {
        return {
          Styles.textStyle: baseStyle.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
          Styles.padding: CascadingPadding.only(top: spacing.md),
        };
      }),
      StyleRule(const BlockSelector("header5"), (doc, docNode) {
        return {
          Styles.textStyle: baseStyle.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
          Styles.padding: CascadingPadding.only(top: spacing.md),
        };
      }),
      StyleRule(const BlockSelector("header6"), (doc, docNode) {
        return {
          Styles.textStyle: baseStyle.copyWith(
            fontWeight: FontWeight.w600,
            fontStyle: FontStyle.italic,
            height: 1.35,
          ),
          Styles.padding: CascadingPadding.only(top: spacing.md),
        };
      }),
      StyleRule(const BlockSelector("listItem"), (doc, docNode) {
        return {Styles.padding: CascadingPadding.only(top: spacing.sm)};
      }),
      // Blockquotes manage their own vertical spacing inside the bordered
      // container so consecutive quoted paragraphs render with a continuous
      // left border instead of a gap from the default block top-margin.
      StyleRule(const BlockSelector("blockquote"), (doc, docNode) {
        return {Styles.padding: const CascadingPadding.only(top: 0)};
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
      // Table styling
      StyleRule(BlockSelector(tableBlockAttribution.name), (doc, docNode) {
        return {
          Styles.padding: CascadingPadding.only(top: spacing.md),
          TableStyles.headerTextStyle: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? context.theme.colors.foreground : null,
          ),
          TableStyles.cellPadding: CascadingPadding.symmetric(
            horizontal: spacing.md,
            vertical: spacing.sm,
          ),
          TableStyles.border: TableBorder.all(
            color: isDark
                ? context.theme.colors.border
                : const Color(0xFFDDDDDD),
            width: 1,
          ),
        };
      }),
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
  }) : _context = context, // ignore: prefer_initializing_formals
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
    // Allow Cmd+Shift+Z (redo) to reach SuperEditor's handler
    if (keyEvent.logicalKey == LogicalKeyboardKey.keyZ) {
      return ExecutionInstruction.continueExecution;
    }
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
  if (character == null || !['.', ',', ';', '!', '?'].contains(character)) {
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
