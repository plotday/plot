import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart' as macos;
import 'package:super_editor/super_editor.dart' hide Editor;
import 'package:super_editor/super_editor.dart' as super_editor show Editor;
import 'package:super_editor/super_text_field.dart';

class Editor extends StatefulWidget {
  const Editor({
    required this.label,
    super.key,
  });

  final String label;

  @override
  State<Editor> createState() => EditorState();
}

class EditorState extends State<Editor> {
  late FocusNode _editorFocusNode;
  late ScrollController _scrollController;
  late MutableDocument _document;
  final _textController = ImeAttributedTextEditingController(
    controller:
        AttributedTextEditingController(text: AttributedText('something')),
  );

  @override
  void initState() {
    super.initState();
    _editorFocusNode = FocusNode();
    _scrollController = ScrollController();
    _document = MutableDocument(
      nodes: [
        ParagraphNode(
          id: super_editor.Editor.createNodeId(),
          text: AttributedText('Example Document'),
          metadata: const {
            'blockType': header1Attribution,
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      groupId: "textfields",
      onTapOutside: (_) => _editorFocusNode.unfocus(),
      child: TextFieldBorder(
        focusNode: _editorFocusNode,
        borderBuilder: _borderBuilder,
        child: SuperTextField(
          lineHeight: 1.2,
          focusNode: _editorFocusNode,
          controlsColor: material.Colors.white,
          configuration: SuperTextFieldPlatformConfiguration.desktop,
          textController: _textController,
          textStyleBuilder: _textStyleBuilder,
          hintBuilder: _createHintBuilder(widget.label),
          hintBehavior: HintBehavior.displayHintUntilTextEntered,
          padding: const EdgeInsets.all(4),
          minLines: 1,
          maxLines: 5,
          inputSource: TextInputSource.keyboard,
        ),
      ),
    );
  }

  BoxDecoration _borderBuilder(TextFieldBorderState borderState) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(7),
      color: borderState.hasFocus
          ? material.Colors.transparent
          : macos.MacosDynamicColor.maybeResolve(
              macos.MacosColors.controlBackgroundColor,
              context,
            ),
      border: Border.all(
        color: borderState.hasError
            ? material.Colors.red
            : borderState.hasFocus
                ? macos.MacosTheme.of(context).brightness.isDark
                    ? const Color.fromRGBO(26, 169, 255, 0.3)
                    : const Color.fromRGBO(0, 103, 244, 0.25)
                : material.Colors.transparent,
        width: 3,
      ),
    );
  }

  TextStyle _textStyleBuilder(Set<Attribution> attributions) {
    return macos.MacosTheme.of(context).typography.body;
  }

  WidgetBuilder _createHintBuilder(String hintText) {
    return (BuildContext context) {
      return Text(
        hintText,
        style: macos.MacosTheme.of(context).typography.body.merge(
              TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: macos.MacosDynamicColor.maybeResolve(
                  CupertinoColors.placeholderText,
                  context,
                ),
              ),
            ),
      );
    };
  }
}
