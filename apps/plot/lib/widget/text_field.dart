import 'package:flutter/widgets.dart';
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
    super.key,
  });

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextEditingController? controller;
  final String label;
  final String? value;

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
      ),
      builder: (_) => material.TextField(
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
        controller: _controller,
        decoration: material.InputDecoration(
          labelText: widget.label,
        ),
      ),
    );
  }
}
