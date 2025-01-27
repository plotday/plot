import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:super_editor_markdown/super_editor_markdown.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'button.dart';
import 'sliver.dart';

final _styles = Stylesheet(
  inlineTextStyler: defaultInlineTextStyler,
  documentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
  rules: [
    StyleRule(
      BlockSelector.all,
      (doc, docNode) {
        return {
          Styles.textStyle: const TextStyle(
            color: material.Colors.white,
            fontSize: 14,
            height: 1.4,
          ),
        };
      },
    ),
  ],
);

class Editor extends StatefulWidget {
  const Editor({
    this.hint,
    this.autofocus = false,
    this.onSubmitted,
    super.key,
  });

  final String? hint;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

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
  bool _isEmpty = true;

  void clear() {
    setState(() {
      // Clear the document
      _document = MutableDocument.empty();
      _document.addListener((_) {
        setState(() {
          _isEmpty = _document.hasEquivalentContent(MutableDocument.empty());
        });
      });
      _composer = MutableDocumentComposer();
      _editor = createDefaultDocumentEditor(
        document: _document,
        composer: _composer,
        isHistoryEnabled: true,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _editorFocusNode = FocusNode();
    _scrollController = ScrollController();
    clear();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(
          LogicalKeyboardKey.enter,
          meta: true,
        ): () {
          submit();
          _editorFocusNode.requestFocus();
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _editorFocusNode.requestFocus(),
        child: Container(
          decoration: BoxDecoration(
            color: macos.MacosDynamicColor.resolve(
              macos.MacosColors.controlBackgroundColor,
              context,
            ),
            border: Border(
              top: BorderSide(
                width: 1.0,
                color: macos.MacosDynamicColor.resolve(
                  macos.MacosColors.separatorColor,
                  context,
                ),
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SuperEditor(
                autofocus: widget.autofocus,
                editor: _editor,
                focusNode: _editorFocusNode,
                shrinkWrap: true,
                scrollController: _scrollController,
                documentLayoutKey: _docLayoutKey,
                stylesheet: _styles,
                documentOverlayBuilders: [
                  DefaultCaretOverlayBuilder(
                    caretStyle: const CaretStyle()
                        .copyWith(color: material.Colors.white),
                  ),
                ],
                componentBuilders: [
                  TaskComponentBuilder(_editor),
                  ...defaultComponentBuilders,
                ],
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Button(
                      onTap: _isEmpty ? null : submit,
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
  const Viewer({
    required this.markdown,
    super.key,
  });

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
    return BoxToSliverAdapter(
      child: SuperReader(
        document: document,
        stylesheet: _styles,
        selection: _selection,
        selectionLayerLinks: _selectionLayerLinks,
      ),
    );
  }
}
