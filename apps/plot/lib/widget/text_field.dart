import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/layout.dart';
import 'package:plot/style/colors.dart';

enum TextFieldStyle { outline, ghost }

class TextField extends StatefulWidget {
  const TextField({
    required this.label,
    this.style = TextFieldStyle.outline,
    this.onChanged,
    this.onSubmitted,
    this.controller,
    this.value,
    this.autocorrect = true,
    this.maxLines,
    this.textAlign = TextAlign.start,
    this.focusNode,
    this.inputFormatters,
    this.autofocus = false,
    super.key,
  });

  final TextFieldStyle style;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextEditingController? controller;
  final String label;
  final String? value;
  final bool autocorrect;
  final int? maxLines;
  final TextAlign textAlign;
  final FocusNode? focusNode;
  final List<TextInputFormatter>? inputFormatters;
  final bool autofocus;

  @override
  TextFieldState createState() => TextFieldState();
}

class TextFieldState extends State<TextField> {
  late final TextEditingController _controller;
  VoidCallback? _listener;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ?? TextEditingController(text: widget.value);
    if (widget.onChanged != null) {
      _listener = () {
        widget.onChanged?.call(_controller.text);
      };
      _controller.addListener(_listener!);
    }
  }

  @override
  void didUpdateWidget(covariant TextField oldWidget) {
    if (oldWidget.value != widget.value && widget.value != null) {
      _controller.text = widget.value!;
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    if (_listener != null) {
      _controller.removeListener(_listener!);
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      // androidBuilder: (_) => material.TextField(
      //   onChanged: widget.onChanged,
      //   controller: _controller,
      //   decoration: material.InputDecoration(
      //     hintText: widget.label,
      //   ),
      //   autocorrect: widget.autocorrect,
      //   maxLines: widget.maxLines,
      //   textAlign: widget.textAlign,
      //   focusNode: widget.focusNode,
      //   inputFormatters: widget.inputFormatters,
      //   autofocus: widget.autofocus,
      // ),
      builder:
          (_) => KeyboardListener(
            focusNode: FocusNode(),
            onKeyEvent: (KeyEvent event) {
              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
                widget.onSubmitted?.call(_controller.text);
              }
            },
            child: FTextField(
              controller: _controller,
              style:
                  widget.style == TextFieldStyle.outline
                      ? null
                      : (style) => style.copyWith(
                        contentPadding: EdgeInsets.all(0),
                        border: style.border.map(
                          (borderStyle) => borderStyle.copyWith(
                            borderSide: BorderSide(
                              width: 0,
                              style: BorderStyle.none,
                            ),
                          ),
                        ),
                      ),
              hint: widget.label,
              autocorrect: widget.autocorrect,
              maxLines: widget.maxLines,
              textAlign: widget.textAlign,
              focusNode: widget.focusNode,
              inputFormatters: widget.inputFormatters,
              autofocus: widget.autofocus,
            ),
          ),
    );
  }
}

enum EditableAreaPosition { top, bottom, middle }

class EditableArea extends StatefulWidget {
  const EditableArea({
    required this.builder,
    required this.position,
    this.padding = true,
    super.key,
  });

  final Widget Function(BuildContext context, FocusNode focusNode) builder;
  final EditableAreaPosition position;
  final bool padding;

  @override
  EditableAreaState createState() => EditableAreaState();
}

class EditableAreaState extends State<EditableArea> {
  final FocusNode _focusNode = FocusNode();

  /// Request focus on this editable area
  void focus() {
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        _focusNode.requestFocus();
      },
      child: Container(
        padding: widget.padding ? widgetPadding : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: context.colour.editableBackground,
          borderRadius: widget.position == EditableAreaPosition.top
              ? null
              : editorBorderRadius,
          border: widget.position == EditableAreaPosition.top
              ? Border(
                  bottom: BorderSide(
                    width: 1.0,
                    color: context.colour.border,
                  ),
                )
              : Border.all(
                  width: 1.0,
                  color: context.colour.border,
                ),
        ),
        child: widget.builder(context, _focusNode),
      ),
    );
  }
}
