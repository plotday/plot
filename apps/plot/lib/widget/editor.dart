import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:super_editor_markdown/super_editor_markdown.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_debouncer/flutter_debouncer.dart';

import 'sliver.dart';
import 'colour_scheme.dart';
import 'bidirectional_list.dart';

class Editor extends StatefulWidget {
  const Editor({
    this.hint,
    this.autofocus = false,
    this.onSubmitted,
    this.onChange,
    this.focusNode,
    super.key,
  });

  final String? hint;
  final bool autofocus;
  final void Function(String value, {bool alt})? onSubmitted;
  final ValueChanged<String>? onChange;
  final FocusNode? focusNode;

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

  void clear() {
    setState(() {
      _editor.execute([ClearDocumentRequest()]);
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
    final md = serializeDocumentToMarkdown(_document);
    widget.onChange?.call(md);
  }

  void _onFocusChange() {
    if (!_editorFocusNode.hasFocus) {
      notify();
    }
  }

  void _onDocumentChange(List<EditEvent> changeList) {
    setState(() {
      _isEmpty = serializeDocumentToMarkdown(_document).isEmpty;
    });
  }

  late final _documentChangeListener = FunctionalEditListener(
    _onDocumentChange,
  );

  @override
  void initState() {
    super.initState();
    _document = MutableDocument.empty();
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
    clear();
  }

  @override
  void dispose() {
    _editor.removeListener(_documentChangeListener);
    _editorFocusNode.removeListener(_onFocusChange);
    _debouncer.cancel();
    _scrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isDark =
        MediaQuery.of(context).platformBrightness == material.Brightness.dark;
    return Shortcuts(
      shortcuts: _isEmpty
          ? BidirectionalList.shortcuts
          : {
              const SingleActivator(LogicalKeyboardKey.enter): SubmitIntent(),
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  SubmitIntent(alt: true),
            },
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
            shrinkWrap: true,
            scrollController: _scrollController,
            documentLayoutKey: _docLayoutKey,
            documentOverlayBuilders: [
              DefaultCaretOverlayBuilder(
                caretStyle: CaretStyle().copyWith(color: context.colour.accent),
              ),
            ],
            stylesheet: isDark ? _darkStyles : _styles,
            selectionStyle: SelectionStyles(
              selectionColor: context.colour.accentBackground,
            ),
            componentBuilders: [
              if (widget.hint != null)
                HintComponentBuilder(
                  widget.hint!,
                  (context) =>
                      baseTextStyle.copyWith(color: context.colour.muted),
                ),
              TaskComponentBuilder(_editor),
              ...defaultComponentBuilders,
            ],
            // TODO use defaultImeKeyboardActions on mobile
            keyboardActions: [
              _bubbleSpecialKeys,
              if (_isEmpty) _bubbleArrowKeys,
              _shiftEnterToInsertBlockNewline,
              ...defaultKeyboardActions,
            ],
            // ),
          ),
        ),
      ),
    );
  }

  void submit(bool alt) {
    final md = serializeDocumentToMarkdown(_document);
    if (md.trim().isEmpty) return;
    widget.onSubmitted?.call(md, alt: alt);
    clear();
  }
}

class Viewer extends StatefulWidget {
  Viewer({required this.markdown, super.key})
    : document = deserializeMarkdownToDocument(markdown);

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
      _editor = createDefaultDocumentEditor(
        document: deserializeMarkdownToDocument(widget.markdown),
        composer: MutableDocumentComposer(),
      );
    });
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
    bool isDark =
        MediaQuery.of(context).platformBrightness == material.Brightness.dark;
    return BoxToSliverAdapter(
      child: SuperReader(
        editor: _editor,
        stylesheet: isDark ? _darkStyles : _styles,
        // selection: _selection,
        selectionLayerLinks: _selectionLayerLinks,
        selectionStyle: SelectionStyles(
          selectionColor: context.colour.accentBackground,
        ),
        // contentTapDelegateFactory: (context) =>
        //     ViewerTapHandler(context.document, onTap: widget.onTap),
      ),
    );
  }
}

const baseTextStyle = TextStyle(
  color: Color(0xFF000000),
  fontSize: 12,
  height: 1.4,
);

final _styles = Stylesheet(
  rules: [
    StyleRule(BlockSelector.all, (doc, docNode) {
      return {
        Styles.textStyle: baseTextStyle,
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
  inlineTextStyler: defaultInlineTextStyler,
  inlineWidgetBuilders: defaultInlineWidgetBuilderChain,
);

final _darkStyles = _styles.copyWith(
  addRulesAfter: [
    StyleRule(BlockSelector.all, (doc, docNode) {
      return {Styles.textStyle: const TextStyle(color: Color(0xFFFFFFFF))};
    }),
  ],
);

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

ExecutionInstruction _shiftEnterToInsertBlockNewline({
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

  if (!HardwareKeyboard.instance.isShiftPressed) {
    // Ignore in SuperEditor, but allow Shortcuts to handle it.
    return ExecutionInstruction.blocked;
  }

  editContext.editor.execute([
    InsertNewlineAtCaretRequest(super_editor.Editor.createNodeId()),
  ]);

  return ExecutionInstruction.haltExecution;
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

  if (keyEvent.logicalKey != LogicalKeyboardKey.escape) {
    return ExecutionInstruction.continueExecution;
  }

  return ExecutionInstruction.blocked;
}
