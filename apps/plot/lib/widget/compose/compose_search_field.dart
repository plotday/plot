// OutlineInputBorder is used to make the filter field borderless in every
// state (BorderSide.none), letting the fading underline be the only chrome.
// Imported with `show` per the established pattern in widget/text_field.dart
// and widget/date_input.dart.
import 'package:flutter/material.dart' show OutlineInputBorder;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/style/plot_colors.dart';
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
    this.hintDetail,
    this.leading,
    this.autofocus = true,
    this.onChanged,
    this.onSubmit,
    this.onArrowDown,
    this.onArrowUp,
    this.onEscape,
    this.activeListenable,
  });

  /// The text editing controller. The parent is the source of truth and reads
  /// text directly from this controller.
  final TextEditingController controller;

  /// Focus node for the search field. Also drives the underline animation.
  final FocusNode focusNode;

  /// Placeholder shown when the field is empty.
  final String hint;

  /// Optional smaller (size `sm`) continuation of the placeholder, rendered on
  /// the same line after [hint] when the field is empty (e.g. "Start a thread"
  /// + " with a name, email, channel, or focus"). When set, the placeholder is
  /// painted as a custom overlay so the two text sizes can coexist — the
  /// field's built-in single-style hint can't.
  final String? hintDetail;

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

  /// When non-null, the [hint] portion of the placeholder (not [hintDetail]) is
  /// boosted toward `foreground` while this listenable reads `false`
  /// ("inactive"). Hosts that fade the whole field's opacity in their inactive
  /// state pass their active-state here so the leading hint (e.g. "Start a
  /// thread") holds its apparent level through the fade while the smaller
  /// [hintDetail] keeps fading with the panel. Null = no boost (constant color).
  /// Only meaningful together with [hintDetail].
  final ValueListenable<bool>? activeListenable;

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
      final hasModifier =
          HardwareKeyboard.instance.isMetaPressed ||
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isAltPressed ||
          HardwareKeyboard.instance.isShiftPressed;
      if (hasModifier) return KeyEventResult.ignored;
      final handler = key == LogicalKeyboardKey.arrowDown
          ? onArrowDown
          : onArrowUp;
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

  /// Wraps [field] so that, while [hintDetail] is set and the field is empty, a
  /// two-size placeholder is painted over it: [hint] at the field's prompt size
  /// and [hintDetail] one step smaller (`sm`) on the same line. The field's own
  /// hint is suppressed in this case (see `hint:` above). Without [hintDetail]
  /// the field is returned untouched.
  Widget _withHintOverlay(BuildContext context, Widget field) {
    final detail = hintDetail;
    if (detail == null) return field;

    final typography = context.theme.typography;
    // The hint's "active" colour. When [activeListenable] reads false the host
    // has faded this field's opacity (~0.55), so the hint colour is boosted
    // toward [boostColor] (`foreground`); 0.55 × foreground lands back ≈
    // mutedForeground, holding the hint's apparent level. The smaller detail is
    // not boosted, so it keeps fading with the panel.
    final activeColor = context.theme.colors.mutedForeground;
    final boostColor = context.theme.colors.foreground;
    final detailColor = context.theme.plotColors.veryMuted;

    // Builds the two-size placeholder with the given (possibly animating) colour
    // for the leading [hint]; the [detail] colour is constant.
    Widget overlay(Color hintColor) {
      return Padding(
        // Match the field's right content padding, but offset the left by the
        // field's padding (4) PLUS the caret width and a hair of gap so the
        // blinking caret sits cleanly *before* the first placeholder glyph
        // rather than overlapping it. (The field's content padding is `4`.)
        padding: const EdgeInsets.only(left: 8, right: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: hint,
                  style: typography.md.copyWith(
                    fontSize: typography.lg.fontSize,
                    color: hintColor,
                  ),
                ),
                TextSpan(
                  text: ' $detail',
                  style: typography.lg.copyWith(color: detailColor),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Stack(
      children: [
        field,
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (value.text.isNotEmpty) return const SizedBox.shrink();
                final boost = activeListenable;
                if (boost == null) return overlay(activeColor);
                // Animate the hint colour in step with the host's opacity fade
                // (same 250ms / easeOut) so the apparent level stays steady
                // through the transition rather than flashing.
                return ValueListenableBuilder<bool>(
                  valueListenable: boost,
                  builder: (context, active, _) {
                    return TweenAnimationBuilder<Color?>(
                      tween: ColorTween(
                        begin: activeColor,
                        end: active ? activeColor : boostColor,
                      ),
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      builder: (context, color, _) =>
                          overlay(color ?? activeColor),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
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
                child: _withHintOverlay(
                  context,
                  FTextField(
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
                    // When a smaller [hintDetail] is supplied the placeholder is
                    // painted by [_withHintOverlay] (two text sizes), so suppress
                    // the field's own single-style hint.
                    hint: hintDetail == null ? hint : null,
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
                        FVariantValueDeltaOperation.exact({
                          FTextFieldVariantConstraint.focused,
                        }, const Color(0x00000000)),
                      ]),
                      // A calm step above the rows (Typography.md, 15 px) so the
                      // prompt reads as the focal entry point.
                      contentTextStyle: FVariantsDelta.delta([
                        FVariantOperation.all(
                          TextStyleDelta.delta(
                            fontSize: typography.lg.fontSize,
                          ),
                        ),
                      ]),
                      hintTextStyle: FVariantsDelta.delta([
                        FVariantOperation.all(
                          TextStyleDelta.delta(
                            fontSize: typography.lg.fontSize,
                          ),
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
