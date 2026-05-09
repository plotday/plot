import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:platform_builder/platform_builder.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/layout.dart';
import 'package:plot/style/plot_colors.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/util/platform.dart';
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
    this.obscureText = false,
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
  final bool obscureText;

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
        obscureText: widget.obscureText,
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
  // Flutter's FocusManager auto-clears primaryFocus to the Root Focus Scope
  // on every inactive/hidden/paused lifecycle transition (focus_manager.dart
  // `_appLifecycleChange` calls `applyFocusChangesIfNeeded` synchronously).
  // On macOS those transitions fire spuriously at launch (widget refresh,
  // dock/window animations) — and worse, often without a follow-up
  // `resumed`, so the app sits in `inactive` indefinitely with no focus
  // owner. That breaks every CallbackShortcuts in the page tree because no
  // descendant widget is in the focus chain.
  //
  // Touch platforms tie focus to the soft keyboard, so silently re-claiming
  // focus there would re-open the keyboard after every backgrounding.
  // Restrict the workaround to physical-keyboard platforms.
  bool _lastHadFocus = false;

  @override
  void initState() {
    super.initState();
    if (hasPhysicalKeyboard()) {
      _focusNode.addListener(_reclaimFocusIfClearedToRoot);
    }

    // Request focus after first frame if autofocus is true
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _reclaimFocusIfClearedToRoot() {
    final hasFocus = _focusNode.hasFocus;
    if (_lastHadFocus && !hasFocus) {
      final primary = FocusManager.instance.primaryFocus;
      if (identical(primary, FocusManager.instance.rootScope)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _focusNode.hasFocus) return;
          // Re-check that primaryFocus is still root — if the user has
          // since clicked into another widget, don't fight them for focus.
          if (!identical(
            FocusManager.instance.primaryFocus,
            FocusManager.instance.rootScope,
          )) {
            return;
          }
          _focusNode.requestFocus();
        });
      }
    }
    _lastHadFocus = hasFocus;
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
    if (hasPhysicalKeyboard()) {
      _focusNode.removeListener(_reclaimFocusIfClearedToRoot);
    }
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
    // Read viewInsets to establish dependency - causes rebuild when keyboard state changes
    MediaQuery.of(context).viewInsets.bottom;

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
