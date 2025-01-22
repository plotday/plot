import 'package:flutter/widgets.dart';
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:super_editor_markdown/super_editor_markdown.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;

import 'button.dart';

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

  @override
  void initState() {
    super.initState();
    _editorFocusNode = FocusNode();
    _scrollController = ScrollController();
    _document = MutableDocument(nodes: [
      ParagraphNode(
        id: super_editor.Editor.createNodeId(),
        text: AttributedText(),
      ),
    ]);
    _composer = MutableDocumentComposer();
    _editor = createDefaultDocumentEditor(
      document: _document,
      composer: _composer,
      isHistoryEnabled: true,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
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
            editor: _editor,
            focusNode: _editorFocusNode,
            shrinkWrap: true,
            scrollController: _scrollController,
            documentLayoutKey: _docLayoutKey,
            stylesheet: Stylesheet(
              inlineTextStyler: defaultInlineTextStyler,
              documentPadding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
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
            ),
            documentOverlayBuilders: [
              DefaultCaretOverlayBuilder(
                caretStyle:
                    const CaretStyle().copyWith(color: material.Colors.white),
              ),
            ],
            componentBuilders: [
              TaskComponentBuilder(_editor),
              ...defaultComponentBuilders,
            ],
          ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Button(
              onTap: () {
                final md = serializeDocumentToMarkdown(_document);
                widget.onSubmitted?.call(md);
              },
              child: const Text('Add'),
            ),
          ]),
        ],
      ),
    );
  }
}
