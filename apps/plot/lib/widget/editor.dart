import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:super_editor_markdown/super_editor_markdown.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter_debouncer/flutter_debouncer.dart';

import 'sliver.dart';

final _styles = Stylesheet(
  rules: [
    StyleRule(BlockSelector.all, (doc, docNode) {
      return {
        Styles.textStyle: const TextStyle(
          color: Color(0xFF000000),
          fontSize: 14,
          height: 1.4,
        ),
        Styles.padding: const CascadingPadding.only(bottom: 14),
      };
    }),
    StyleRule(BlockSelector.all.last(), (doc, docNode) {
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

class Editor extends StatefulWidget {
  const Editor({
    this.hint,
    this.autofocus = false,
    this.onSubmitted,
    this.onChange,
    super.key,
  });

  final String? hint;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChange;

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

  void clear() {
    setState(() {
      // Clear the document
      _document = MutableDocument.empty();
      _document.addListener(_onDocumentChanged);
      _composer = MutableDocumentComposer();
      _editor = createDefaultDocumentEditor(
        document: _document,
        composer: _composer,
        isHistoryEnabled: true,
      );
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

  @override
  void initState() {
    super.initState();
    _editorFocusNode =
        FocusNode()..addListener(() {
          if (!_editorFocusNode.hasFocus) {
            notify();
          }
        });
    _scrollController = ScrollController();
    clear();
  }

  @override
  void dispose() {
    _debouncer.cancel();
    _scrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isDark =
        MediaQuery.of(context).platformBrightness == material.Brightness.dark;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          submit();
          _editorFocusNode.requestFocus();
        },
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
              caretStyle: CaretStyle().copyWith(
                color: isDark ? material.Colors.white : material.Colors.black,
              ),
            ),
          ],
          stylesheet: isDark ? _darkStyles : _styles,
          componentBuilders: [
            TaskComponentBuilder(_editor),
            ...defaultComponentBuilders,
          ],
        ),
      ),
    );
  }

  void submit() {
    final md = serializeDocumentToMarkdown(_document);
    widget.onSubmitted?.call(md);
    clear();
  }
}

class Viewer extends StatefulWidget {
  const Viewer({required this.markdown, super.key});

  final String markdown;

  @override
  ViewerState createState() => ViewerState();
}

class ViewerState extends State<Viewer> {
  late Document document; // no need for `late final` if we're updating it
  late final ValueNotifier<DocumentSelection?> _selection;
  final _selectionLayerLinks = SelectionLayerLinks();

  @override
  void initState() {
    super.initState();
    // Initialize the Document and ValueNotifier
    _initializeDocumentAndSelection();
  }

  // Utility method for initialization that's reusable
  void _initializeDocumentAndSelection() {
    document = deserializeMarkdownToDocument(widget.markdown);
    _selection = ValueNotifier<DocumentSelection?>(null);
  }

  @override
  void didUpdateWidget(Viewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Check if markdown has changed
    if (oldWidget.markdown != widget.markdown) {
      // Update the document when the markdown changes
      setState(() {
        document = deserializeMarkdownToDocument(widget.markdown);
      });
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
        document: document,
        stylesheet: isDark ? _darkStyles : _styles,
        selection: _selection,
        selectionLayerLinks: _selectionLayerLinks,
      ),
    );
  }
}
