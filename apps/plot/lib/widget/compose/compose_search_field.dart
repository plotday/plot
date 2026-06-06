// OutlineInputBorder is used to make the filter field borderless in every
// state (BorderSide.none), letting the fading underline be the only chrome.
// Imported with `show` per the established pattern in widget/text_field.dart
// and widget/date_input.dart.
import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/util/platform.dart';
import 'package:plot/widget/fading_underline.dart';

/// A reusable borderless search input with a fading underline, a leading slot,
/// and keyboard-navigation callbacks (Enter / ↓ / Escape).
///
/// Visual chrome is identical to the step-1 new-thread filter:
/// transparent fill in every state, [Typography.lg]
/// text/hint, borderless in all focus states, and the always-laid-out clear-✕
/// suffix that keeps the field height stable regardless of whether the field
/// has text. The [_FadingUnderline] below the row provides the only focus cue.
///
/// This widget is purely controlled: the parent owns [controller] and
/// [focusNode] and reads [controller.text] directly. Callers are notified of
/// changes via [onChanged] (no value delivered — read [controller.text]).
class ComposeSearchField extends StatelessWidget {
  const ComposeSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    this.leading,
    this.autofocus = true,
    this.onChanged,
    this.onSubmit,
    this.onArrowDown,
    this.onArrowUp,
    this.onEscape,
  });

  /// The text editing controller. The parent is the source of truth and reads
  /// text directly from this controller.
  final TextEditingController controller;

  /// Focus node for the search field. Also drives the underline animation.
  final FocusNode focusNode;

  /// Placeholder shown when the field is empty.
  final String hint;

  /// Optional leading widget (e.g. a search icon in step 1, a recipient chip
  /// in step 2). Rendered with a small right gap before the field.
  final Widget? leading;

  /// Whether to auto-focus the field when first mounted.
  final bool autofocus;

  /// Fired whenever the field text changes. The caller reads [controller.text]
  /// directly — no value is passed.
  final VoidCallback? onChanged;

  /// Fired when the user presses Enter.
  final VoidCallback? onSubmit;

  /// Fired when the user presses a bare ↓ (no modifiers). Intended to move the
  /// highlighted row in the list below one step down — keyboard focus stays on
  /// this field. A modified ↓ (e.g. ⌘/Ctrl+↓ = next thread) is left to
  /// propagate to the global shortcuts.
  final VoidCallback? onArrowDown;

  /// Fired when the user presses a bare ↑ (no modifiers). Moves the highlighted
  /// row in the list below one step up. A modified ↑ (e.g. ⌘/Ctrl+↑ = previous
  /// thread) is left to propagate to the global shortcuts.
  final VoidCallback? onArrowUp;

  /// Fired when the user presses Escape. Return true if handled (suppresses
  /// further propagation), false to let the event propagate.
  ///
  /// When null, the original behaviour is preserved: Escape clears the field
  /// when it has text, and is ignored when it is already empty.
  final bool Function()? onEscape;

  /// Clears the controller and fires [onChanged] so the parent re-filters.
  void _clear() {
    controller.clear();
    onChanged?.call();
    focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      // Only bare arrows drive the list highlight. A modified arrow — notably
      // ⌘/Ctrl+↑/↓ (previous/next thread) — must reach the global command
      // shortcuts, so don't consume it here.
      final hasModifier = HardwareKeyboard.instance.isMetaPressed ||
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed ||
          HardwareKeyboard.instance.isShiftPressed;
      if (hasModifier) return KeyEventResult.ignored;
      final handler =
          key == LogicalKeyboardKey.arrowDown ? onArrowDown : onArrowUp;
      if (handler == null) return KeyEventResult.ignored;
      handler();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (onEscape != null) {
        final handled = onEscape!();
        return handled ? KeyEventResult.handled : KeyEventResult.ignored;
      }
      // Default behaviour: clear when text is present.
      if (controller.text.isNotEmpty) {
        _clear();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final typography = context.theme.typography;
    final colors = context.theme.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (leading != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: leading!,
              ),
            Expanded(
              child: Focus(
                canRequestFocus: false,
                onKeyEvent: _onKey,
                child: FTextField(
                  // The parent reads `controller.text` directly, so onChange
                  // just needs to notify the caller that something changed.
                  control: .managed(
                    controller: controller,
                    onChange: (_) => onChanged?.call(),
                  ),
                  focusNode: focusNode,
                  autofocus: autofocus && hasPhysicalKeyboard(),
                  // Keep focus on the field when the user clicks empty space on
                  // the compose page — Flutter's text field unfocuses itself on
                  // any tap outside its tap region by default. Overriding
                  // onTapOutside with a no-op suppresses that so a stray click
                  // around the field doesn't drop the user out of the filter.
                  onTapOutside: (_) {},
                  hint: hint,
                  style: FTextFieldStyleDelta.delta(
                    // Roomy vertical padding so the field reads as an open
                    // prompt rather than a boxed input. No `minHeight` floor:
                    // the always-laid-out clear-button suffix (below) sets a
                    // stable height and centres the text.
                    contentPadding: EdgeInsetsGeometryDelta.value(
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                    ),
                    // Transparent fill in EVERY state — the global text-field
                    // delta fills the field with `editableBackground` on focus;
                    // without this override the borderless prompt would grow a
                    // focus background. The fading underline is the only focus
                    // cue.
                    color: FVariantsValueDelta.delta([
                      FVariantValueDeltaOperation.all(
                        const Color(0x00000000),
                      ),
                      FVariantValueDeltaOperation.exact(
                        {FTextFieldVariantConstraint.focused},
                        const Color(0x00000000),
                      ),
                    ]),
                    // A calm step above the rows (Typography.md, 15 px) so the
                    // prompt reads as the focal entry point.
                    contentTextStyle: FVariantsDelta.delta([
                      FVariantOperation.all(
                        TextStyleDelta.delta(fontSize: typography.lg.fontSize),
                      ),
                    ]),
                    hintTextStyle: FVariantsDelta.delta([
                      FVariantOperation.all(
                        TextStyleDelta.delta(fontSize: typography.lg.fontSize),
                      ),
                    ]),
                    // Borderless in every state — the fading underline below is
                    // the only chrome. The focused override is explicit because
                    // the app theme otherwise paints a focused accent border
                    // that the `all` override does not replace.
                    border: FVariantsValueDelta.delta([
                      FVariantValueDeltaOperation.all(
                        const OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                      FVariantValueDeltaOperation.exact(
                        {FTextFieldVariantConstraint.focused},
                        const OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                    ]),
                  ),
                  // Trailing clear "✕" inside the input. Always laid out so the
                  // field takes its stable height from it rather than a
                  // `minHeight` floor. When the field is empty, the button is
                  // invisible (Opacity 0) and non-interactive (IgnorePointer).
                  // The ValueListenableBuilder rebuilds only this suffix subtree
                  // so toggling it never tears down the editor or drops focus.
                  suffixBuilder: (context, style, states) {
                    return ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final hasText = value.text.isNotEmpty;
                        return Padding(
                          padding: style.clearButtonPadding,
                          child: IgnorePointer(
                            ignoring: !hasText,
                            child: Opacity(
                              opacity: hasText ? 1.0 : 0.0,
                              child: FButton.icon(
                                style: style.clearButtonStyle,
                                onPress: _clear,
                                child: context.theme.icons.x(context),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                  onSubmit: (_) => onSubmit?.call(),
                ),
              ),
            ),
          ],
        ),
        // Fading underline: glows in the centre, dissolves into the page
        // background at both edges; neutral, brightening slightly on focus
        // (no accent tint).
        FadingUnderline(
          focusNode: focusNode,
          color: colors.border,
          focusedColor: colors.foreground.withValues(alpha: 0.3),
        ),
      ],
    );
  }
}
