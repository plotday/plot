import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:super_editor_markdown/super_editor_markdown.dart';
import 'package:flutter_debouncer/flutter_debouncer.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/state/local_preferences.dart';
import 'package:plot/state/settings.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/command/command.dart';
import 'package:plot/util/platform_stub.dart';
import 'sliver.dart';
import 'editor_mention_plugin.dart';
import 'editor_mention_detector.dart';
import 'editor_mention_popover.dart';
import 'logging.dart';

/// Information about a mention extracted from markdown
class _MentionInfo {
  const _MentionInfo({required this.name, required this.priorityTwistId});

  final String name;
  final String priorityTwistId;
}

/// Extract mention info from markdown before preprocessing
List<_MentionInfo> _extractMentions(String markdown) {
  final mentions = <_MentionInfo>[];
  final mentionPattern = RegExp(
    r'\[([^\]]+)\]\(#@([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)',
  );

  for (final match in mentionPattern.allMatches(markdown)) {
    mentions.add(
      _MentionInfo(
        name: match.group(1) ?? '',
        priorityTwistId: match.group(2) ?? '',
      ),
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
        priorityTwistId: mention.priorityTwistId,
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

/// Deserialize markdown with mentions into a MutableDocument
MutableDocument _deserializeMarkdownWithMentions(String markdown) {
  // Extract mentions before preprocessing
  final mentions = _extractMentions(markdown);

  // Preprocess markdown to remove mention syntax
  final preprocessed = _preprocessMarkdown(markdown);

  // Deserialize to base document
  final baseDocument = deserializeMarkdownToDocument(preprocessed);
  final document = MutableDocument(nodes: baseDocument.toList());

  // Add mention attributions
  for (final mention in mentions) {
    _addMentionAttributions(document, mention);
  }

  return document;
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
  final bool shrinkWrap;
  final String? initialContent;

  @override
  State<Editor> createState() => EditorState();
}

class EditorState extends State<Editor> {
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
      // Clear the document first
      _editor.execute([ClearDocumentRequest()]);

      // If content is provided, deserialize and insert it
      if (content != null && content.isNotEmpty) {
        final newDocument = _deserializeMarkdownWithMentions(content);

        // Remove the empty paragraph that ClearDocumentRequest leaves behind
        if (_document.nodeCount > 0) {
          for (int i = _document.nodeCount - 1; i >= 0; i--) {
            final node = _document.getNodeAt(i);
            if (node != null) {
              _document.deleteNode(node.id);
            }
          }
        }

        // Insert all nodes from new document
        for (final node in newDocument.toList()) {
          _document.insertNodeAt(_document.nodeCount, node);
        }
      }

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
      duration: const Duration(milliseconds: 500),
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
        final replacement = '[$name](#@${attribution.priorityTwistId})';
        markdown = markdown.replaceFirst(mentionText, replacement);
      }
    }

    return markdown;
  }

  void _onFocusChange() {
    if (!_editorFocusNode.hasFocus) {
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

    // Don't call clear() if we have initial content
    if (widget.initialContent == null || widget.initialContent!.isEmpty) {
      clear();
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

        // Replace document nodes by removing all and inserting new ones
        setState(() {
          // Remove all existing nodes (working backwards to avoid index issues)
          for (int i = _document.nodeCount - 1; i >= 0; i--) {
            final node = _document.getNodeAt(i);
            if (node != null) {
              _document.deleteNode(node.id);
            }
          }

          // Insert all nodes from new document
          for (final node in newDocument.toList()) {
            _document.insertNodeAt(_document.nodeCount, node);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _editor.removeListener(_documentChangeListener);
    _editorFocusNode.removeListener(_onFocusChange);
    _mentionDetector.removeListener(_updateMentionOverlay);
    _debouncer.cancel();
    _scrollController.dispose();
    // Only dispose the FocusNode if we created it
    if (widget.focusNode == null) {
      _editorFocusNode.dispose();
    }
    _mentionDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isDark = context.read<ThemeBloc>().isDarkMode(context);
    final settingsState = context.watch<SettingsBloc>().state;

    return OverlayPortal(
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
                submit(intent.alt);
                return KeyEventResult.handled;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _editorFocusNode.requestFocus(),
            child: SuperEditor(
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
                TaskComponentBuilder(_editor),
                ...defaultComponentBuilders,
              ],
              keyboardActions: [
                if (_isEmpty) _bubbleArrowKeys,
                _handleMentionPopoverNavigation,
                _buildEnterKeyHandler(settingsState.enterBehavior),
                _handlePunctuationAfterMention,
                _handleBackspaceOverMention,
                // Use IME keyboard actions on mobile, regular keyboard actions on desktop
                ...(_inputSource == TextInputSource.ime
                    ? defaultImeKeyboardActions
                    : defaultKeyboardActions),
                _bubbleSpecialKeys,
              ],
            ),
          ),
        ),
      ),
    );
  }

  void submit(bool alt) async {
    final md = _serializeWithMentions(_document);

    // Show first-time prompt if needed (only on devices with physical keyboards)
    final settingsBloc = context.read<SettingsBloc>();
    if (hasPhysicalKeyboard() &&
        !settingsBloc.state.hasBeenPromptedForEnterBehavior) {
      await _showEnterBehaviorPrompt();
      return;
    }

    widget.onSubmitted?.call(md, alt: alt);
    clear();
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
  DocumentKeyboardAction _buildEnterKeyHandler(EnterBehavior behavior) {
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

  /// Show first-time prompt for enter key behavior selection
  Future<void> _showEnterBehaviorPrompt() async {
    context.run(ChangeEnterBehavior());
  }

  /// Get the current editor content as markdown
  String serialize() {
    return _serializeWithMentions(_document);
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
  DocumentKeyboardAction get _handleMentionPopoverNavigation {
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
    // Listen to mention detector to show/hide overlay
    _mentionDetector.addListener(_updateMentionOverlay);
  }

  void _updateMentionOverlay() {
    final mention = _mentionDetector.composingMention;

    // Filter twists based on composing text
    final hasMatches =
        mention != null &&
        widget.twists.any(
          (twist) =>
              twist.name.toLowerCase().contains(mention.text.toLowerCase()),
        );

    if (hasMatches && !_mentionOverlayController.isShowing) {
      _mentionOverlayController.show();
    } else if (!hasMatches && _mentionOverlayController.isShowing) {
      _mentionOverlayController.hide();
    }
  }

  /// Builds the user mention popover in the overlay
  Widget _buildEditorMentionPopover(BuildContext context) {
    final mentionBeingComposed = _mentionDetector.composingMention;
    if (mentionBeingComposed == null || widget.twists.isEmpty) {
      return const SizedBox.shrink();
    }

    // Sort twists by most-recently-used
    final localPrefs = context.read<LocalPreferencesBloc>();
    final sortedTwists = localPrefs.sortByMentionMru(
      widget.twists,
      (twist) => twist.id.toString(),
    );

    return EditorMentionPopover(
      key: _mentionPopoverKey,
      editorFocusNode: _editorFocusNode,
      leaderLink: _mentionLeaderLink,
      twists: sortedTwists,
      composingText: mentionBeingComposed.text,
      showAbove: _showMentionPopoverAbove,
      onAgentSelected: (twist) {
        // Record mention usage for MRU sorting
        localPrefs.recordMentionUsage(twist.id.toString());

        _mentionDetector.completeMention(
          priorityTwistId: twist.id.toString(),
          username: twist.name,
        );
        _editorFocusNode.requestFocus();
      },
      onCancelRequested: () {
        _mentionDetector.cancelMention();
        _editorFocusNode.requestFocus();
      },
    );
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
          offset: Offset(triggerRect.left, triggerRect.bottom + 4),
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
    const spacing = 4.0;
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
    bool isDark = context.read<ThemeBloc>().isDarkMode(context);
    return BoxToSliverAdapter(
      child: SuperReader(
        editor: _editor,
        stylesheet: _buildStylesheet(context, isDark),
        // selection: _selection,
        selectionLayerLinks: _selectionLayerLinks,
        selectionStyle: SelectionStyles(
          selectionColor: context.theme.colors.primaryForeground,
        ),
        // contentTapDelegateFactory: (context) =>
        //     ViewerTapHandler(context.document, onTap: widget.onTap),
      ),
    );
  }
}

TextStyle _baseTextStyle(BuildContext context) {
  return context.theme.typography.base.copyWith(height: 1.4);
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

  // Apply dark theme base color if no specific attribution styling is applied
  if (isDark &&
      !attributions.contains(editorMentionComposingAttribution) &&
      !attributions.whereType<CommittedEditorMentionAttribution>().isNotEmpty) {
    style = style.copyWith(color: context.theme.colors.foreground);
  }

  return style;
}

Stylesheet _buildStylesheet(BuildContext context, bool isDark) {
  final baseStyle = _baseTextStyle(
    context,
  ).copyWith(color: isDark ? context.theme.colors.foreground : null);

  return Stylesheet(
    rules: [
      StyleRule(BlockSelector.all, (doc, docNode) {
        return {
          Styles.textStyle: baseStyle,
          Styles.padding: const CascadingPadding.only(bottom: 14),
        };
      }),
      StyleRule(BlockSelector.all.last(), (doc, docNode) {
        return {Styles.padding: const CascadingPadding.only(bottom: 0)};
      }),
      StyleRule(const BlockSelector("listItem"), (doc, docNode) {
        return {Styles.padding: const CascadingPadding.only(bottom: 0)};
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
  ViewerTapHandler(super.document, {void Function()? onTap}) : _handler = onTap;

  final void Function()? _handler;

  @override
  MouseCursor? mouseCursorForContentHover(DocumentPosition hoverPosition) {
    return super.mouseCursorForContentHover(hoverPosition) ??
        (_handler != null ? SystemMouseCursors.basic : null);
  }

  @override
  TapHandlingInstruction onTap(DocumentTapDetails details) {
    final instructions = super.onTap(details);
    if (instructions != TapHandlingInstruction.halt && _handler != null) {
      _handler();
      return TapHandlingInstruction.halt;
    }
    return instructions;
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

  // Bubble up meta key combos
  final isMetaPressed =
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isControlPressed;
  if (isMetaPressed) {
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
