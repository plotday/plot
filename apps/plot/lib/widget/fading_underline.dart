import 'package:flutter/widgets.dart';

/// A ~1.5px horizontal hairline that glows in the centre and dissolves into
/// the page background at both ends (a gradient from transparent → [color] →
/// transparent). The sole chrome under a borderless search input. It brightens
/// from [color] to [focusedColor] when [focusNode] gains focus, animated so the
/// transition reads as calm. The colour stays neutral — no accent tint —
/// consistent with the picker's deliberately un-tinted focus state.
///
/// Shared by the step-1 new-thread filter ([ComposeSearchField]) and the
/// header search field so both read as the same "open prompt" chrome.
class FadingUnderline extends StatelessWidget {
  const FadingUnderline({
    super.key,
    required this.focusNode,
    required this.color,
    required this.focusedColor,
  });

  final FocusNode focusNode;
  final Color color;
  final Color focusedColor;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, _) {
        final line = focusNode.hasFocus ? focusedColor : color;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 1.5,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                line.withValues(alpha: 0),
                line,
                line,
                line.withValues(alpha: 0),
              ],
              stops: const [0.0, 0.18, 0.82, 1.0],
            ),
          ),
        );
      },
    );
  }
}
