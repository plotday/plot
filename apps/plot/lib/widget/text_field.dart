import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/modal.dart';

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
      var previousText = _controller.text;
      _listener = () {
        if (_controller.text != previousText) {
          previousText = _controller.text;
          widget.onChanged?.call(_controller.text);
        }
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
      builder: (_) => FTextField(
        control: .managed(controller: _controller),
        style: widget.style == TextFieldStyle.outline
            ? const FTextFieldStyleDelta.context()
            : FTextFieldStyleDelta.delta(
                contentPadding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
                color: FVariantsValueDelta.delta([
                  FVariantValueDeltaOperation.all(const Color(0x00000000)),
                ]),
                border: FVariantsValueDelta.delta([
                  FVariantValueDeltaOperation.all(
                    OutlineInputBorder(
                      borderSide: BorderSide(width: 0, style: BorderStyle.none),
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ]),
              ),
        hint: widget.label,
        autocorrect: widget.autocorrect,
        maxLines: widget.maxLines,
        textAlign: widget.textAlign,
        focusNode: widget.focusNode,
        inputFormatters: widget.inputFormatters,
        autofocus: widget.autofocus,
        onSubmit: widget.onSubmitted != null
            ? (_) => widget.onSubmitted!(_controller.text)
            : null,
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
    this.autofocus = false,
    this.flushToBottom = false,
    super.key,
  });

  final Widget Function(BuildContext context, FocusNode focusNode) builder;
  final EditableAreaPosition position;
  final bool padding;
  final bool autofocus;
  final bool flushToBottom;

  @override
  EditableAreaState createState() => EditableAreaState();
}

class EditableAreaState extends State<EditableArea> {
  final FocusNode _focusNode = FocusNode();
  ValueNotifier<int>? _modalStackNotifier;
  int? _previousStackDepth;

  @override
  void initState() {
    super.initState();

    // Request focus after first frame if autofocus is true
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Listen to modal stack changes to restore focus when this modal becomes visible again
    if (widget.autofocus) {
      try {
        final modalProvider = ModalProvider.of(context);
        final notifier = modalProvider.modalStackNotifier;

        // Remove old listener if it exists
        if (_modalStackNotifier != null && _modalStackNotifier != notifier) {
          _modalStackNotifier!.removeListener(_onModalStackChanged);
        }

        // Add new listener if needed
        if (_modalStackNotifier != notifier) {
          _modalStackNotifier = notifier;
          _previousStackDepth = notifier.value;
          _modalStackNotifier!.addListener(_onModalStackChanged);
        }
      } catch (e) {
        // ModalProvider not available in this context
      }
    }
  }

  void _onModalStackChanged() {
    final currentDepth = _modalStackNotifier!.value;

    // If the stack depth decreased (modal was popped) and we don't have focus, request it
    if (_previousStackDepth != null &&
        currentDepth < _previousStackDepth! &&
        !_focusNode.hasFocus &&
        widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_focusNode.hasFocus) {
          _focusNode.requestFocus();
        }
      });
    }

    _previousStackDepth = currentDepth;
  }

  @override
  void dispose() {
    if (_modalStackNotifier != null) {
      _modalStackNotifier!.removeListener(_onModalStackChanged);
    }
    _focusNode.dispose();
    super.dispose();
  }

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
        padding: widget.padding ? context.theme.spacing.padding : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: context.theme.plotColors.editableBackground,
          borderRadius: widget.flushToBottom
              ? null
              : (widget.position == EditableAreaPosition.top
                  ? null
                  : editorBorderRadius),
          border: widget.flushToBottom
              ? Border(
                  top: BorderSide(
                    width: 1.0,
                    color: context.theme.colors.border,
                  ),
                )
              : (widget.position == EditableAreaPosition.top
                  ? Border(
                      bottom: BorderSide(
                        width: 1.0,
                        color: context.theme.colors.border,
                      ),
                    )
                  : Border.all(width: 1.0, color: context.theme.colors.border)),
        ),
        child: widget.builder(context, _focusNode),
      ),
    );
  }
}
