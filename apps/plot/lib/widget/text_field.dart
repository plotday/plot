import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as material;
import 'package:macos_ui/macos_ui.dart';
import 'package:platform_builder/platform_builder.dart';

class TextField extends StatefulWidget {
  const TextField({
    required this.label,
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
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ?? TextEditingController(text: widget.value);
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
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuilder(
      macOSBuilder: (_) => MacosTextField(
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        controller: _controller,
        placeholder: widget.label,
        autocorrect: widget.autocorrect,
        maxLines: widget.maxLines,
        textAlign: widget.textAlign,
        focusNode: widget.focusNode,
        inputFormatters: widget.inputFormatters,
        autofocus: widget.autofocus,
      ),
      builder: (_) => material.TextField(
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        controller: _controller,
        decoration: material.InputDecoration(
          hintText: widget.label,
        ),
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
