import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:forui/forui.dart';

import 'theme.dart';
import 'colour_scheme.dart';

enum TextFieldStyle { outline, ghost }

class TextField extends StatefulWidget {
  const TextField({
    required this.label,
    this.style = TextFieldStyle.outline,
    this.onChanged,
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

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ?? TextEditingController(text: widget.value);
    if (widget.onChanged != null) {
      _controller.addListener(() {
        widget.onChanged?.call(_controller.text);
      });
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
    if (widget.onChanged != null) {
      _controller.removeListener(() {
        widget.onChanged?.call(_controller.text);
      });
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final borderless = FTextFieldBorderStyle(
      color: Color(0x00FFFFFF),
      width: 0,
      radius: BorderRadius.zero,
    );
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
          (_) => FTextField(
            controller: _controller,
            style:
                widget.style == TextFieldStyle.outline
                    ? null
                    : context.theme.textFieldStyle.copyWith(
                      contentPadding: EdgeInsets.all(0),
                      enabledStyle: context.theme.textFieldStyle.enabledStyle
                          .copyWith(
                            unfocusedStyle: borderless,
                            focusedStyle: borderless,
                          ),
                      disabledStyle: context.theme.textFieldStyle.disabledStyle
                          .copyWith(
                            unfocusedStyle: borderless,
                            focusedStyle: borderless,
                          ),
                      errorStyle: context.theme.textFieldStyle.errorStyle
                          .copyWith(
                            unfocusedStyle: borderless,
                            focusedStyle: borderless,
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
          border: Border(
            top:
                widget.position != EditableAreaPosition.top
                    ? BorderSide(width: 1.0, color: context.colour.border)
                    : BorderSide.none,
            bottom:
                widget.position != EditableAreaPosition.bottom
                    ? BorderSide(width: 1.0, color: context.colour.border)
                    : BorderSide.none,
          ),
        ),
        child: widget.builder(context, _focusNode),
      ),
    );
  }
}
