import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

/// A modern OTP input widget with 6 separate input fields.
///
/// Features:
/// - 6 individual input boxes for each digit
/// - Auto-advance to next field when digit is entered
/// - Auto-backspace to previous field on delete
/// - Paste support for 6-digit codes
/// - Auto-submit when all 6 digits are entered
class OtpInput extends StatefulWidget {
  const OtpInput({
    required this.onComplete,
    this.controller,
    this.autofocus = true,
    super.key,
  });

  /// Called when all 6 digits have been entered
  final VoidCallback onComplete;

  /// Optional controller to get/set the OTP value
  final TextEditingController? controller;

  /// Whether to autofocus the first field
  final bool autofocus;

  @override
  State<OtpInput> createState() => _OtpInputState();
}

/// Custom formatter to allow paste but limit typing to 1 digit
class _OtpTextInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Allow paste (multiple characters) or single character typing
    // The widget's onChange handler will deal with distribution
    return newValue;
  }
}

class _OtpInputState extends State<OtpInput> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;
  late final List<FocusNode> _keyboardListenerFocusNodes;
  late final TextEditingController _externalController;

  @override
  void initState() {
    super.initState();

    // Create 6 controllers and focus nodes
    _controllers = List.generate(6, (_) => TextEditingController());
    _focusNodes = List.generate(6, (_) => FocusNode());
    _keyboardListenerFocusNodes = List.generate(6, (_) => FocusNode());

    // Setup external controller if provided
    _externalController = widget.controller ?? TextEditingController();

    // Add listeners to update external controller
    for (var i = 0; i < 6; i++) {
      _controllers[i].addListener(_updateExternalController);
    }

    // Autofocus first field after frame
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNodes[0].requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    for (var i = 0; i < 6; i++) {
      _controllers[i].removeListener(_updateExternalController);
      _controllers[i].dispose();
      _focusNodes[i].dispose();
      _keyboardListenerFocusNodes[i].dispose();
    }
    if (widget.controller == null) {
      _externalController.dispose();
    }
    super.dispose();
  }

  void _updateExternalController() {
    final value = _controllers.map((c) => c.text).join();
    _externalController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _handleKeyEvent(int index, KeyEvent event) {
    // Handle backspace key specifically
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_controllers[index].text.isEmpty && index > 0) {
        // Field is empty, move to previous field and clear it
        _focusNodes[index - 1].requestFocus();
        _controllers[index - 1].clear();
      }
    }
  }

  void _handleTextChanged(int index, String value) {
    if (value.isEmpty) {
      // Field cleared, do nothing (backspace handled by keyboard listener)
      return;
    }

    if (value.length == 1) {
      // Single character entered - move to next field
      if (index < 5) {
        _focusNodes[index + 1].requestFocus();
      } else {
        // Last field filled - check if all fields are complete
        _checkComplete();
      }
    } else if (value.length > 1) {
      // Multiple characters - this is a paste operation
      // Distribute digits across fields
      _handlePaste(index, value);
    }
  }

  void _handlePaste(int startIndex, String pastedText) {
    // Extract only digits from pasted text
    final digits = pastedText.replaceAll(RegExp(r'\D'), '');

    if (digits.isEmpty) return;

    // Use post-frame callback to ensure the distribution happens after
    // the current onChange event completes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // Distribute digits across fields starting from current index
      for (var i = 0; i < digits.length && startIndex + i < 6; i++) {
        _controllers[startIndex + i].text = digits[i];
      }

      // Move focus to the last filled field or next empty field
      final lastFilledIndex = (startIndex + digits.length - 1).clamp(0, 5);
      if (lastFilledIndex < 5 && digits.length < 6) {
        _focusNodes[lastFilledIndex + 1].requestFocus();
      } else {
        _focusNodes[lastFilledIndex].requestFocus();
        _checkComplete();
      }
    });
  }

  void _checkComplete() {
    // Check if all 6 fields are filled
    final allFilled = _controllers.every((c) => c.text.isNotEmpty);
    if (allFilled) {
      // Unfocus to hide keyboard
      for (final node in _focusNodes) {
        node.unfocus();
      }
      // Call completion callback
      widget.onComplete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: List.generate(
            6,
            (index) => Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: KeyboardListener(
                  focusNode: _keyboardListenerFocusNodes[index],
                  onKeyEvent: (event) => _handleKeyEvent(index, event),
                  child: FTextField(
                    control: .managed(controller: _controllers[index], onChange: (value) => _handleTextChanged(index, value.text)), focusNode: _focusNodes[index],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    autocorrect: false,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      _OtpTextInputFormatter(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
