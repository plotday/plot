import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/widget/emoji.dart';

/// A subtle pill rendering a single active emoji reaction under a note,
/// grouping the emoji with its count into one tappable unit.
///
/// Neutral by default; tinted with the accent colour — at the same subtle
/// base opacity — when the current user is one of the reactors ([mine]).
/// Hover and keyboard focus boost the fill/border contrast. Tapping toggles
/// the current user's reaction via [onPressed].
class ReactionPill extends StatelessWidget {
  const ReactionPill({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.tooltip,
    required this.onPressed,
    this.subtitle,
    this.leadingInset = 0,
    super.key,
  });

  /// The reaction value: a Unicode grapheme cluster or a custom-emoji ref.
  final Reaction emoji;

  /// Number of actors who added this reaction. Only rendered when > 1.
  final int count;

  /// Whether the current user is among the reactors — drives the accent tint.
  final bool mine;

  /// Tooltip title — the emoji's display name.
  final String tooltip;

  /// Optional tooltip subtitle, e.g. the reactor names ("You, Alice +2").
  final String? subtitle;

  /// Toggles the current user's reaction.
  final VoidCallback onPressed;

  /// Extra left margin applied to this pill. The note command row is shifted
  /// left so borderless icon glyphs land on the content's left edge; when a
  /// pill is the leftmost element it needs this inset (the ghost icon
  /// padding) so its *border* aligns with the content instead of poking out.
  final double leadingInset;

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final accent = context.colour.accent;
    final isLight = context.colour.brightness == Brightness.light;
    // Neutral ink the unselected fill is tinted from — near-black in light
    // mode, near-white in dark — matching Slack's low-alpha neutral chip wash.
    final neutralInk = context.colour.foreground;
    // The "you reacted" count picks up the accent; everyone else's stays a
    // readable medium grey (Slack uses ~#616061 / ~#ababad here).
    final countColor = mine ? accent : context.colour.muted;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EmojiCommandIcon(emoji),
        // A lone reaction shows just the emoji; the count appears from 2 up.
        if (count > 1) ...[
          const SizedBox(width: 5),
          Text(
            '$count',
            style: context.theme.typography.xs.copyWith(
              color: countColor,
              height: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );

    return FTooltip(
      tipAnchor: Alignment.bottomCenter,
      childAnchor: Alignment.topCenter,
      tipBuilder: (context, _) {
        final sub = subtitle;
        if (sub == null || sub.isEmpty) return Text(tooltip);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tooltip),
            Text(
              sub,
              style: context.theme.typography.xs.copyWith(
                color: colors.mutedForeground,
              ),
            ),
          ],
        );
      },
      child: FTappable(
        onPress: onPressed,
        semanticsLabel: tooltip,
        builder: (context, states, child) {
          final boosted =
              states.contains(FTappableVariant.hovered) ||
              states.contains(FTappableVariant.focused) ||
              states.contains(FTappableVariant.pressed);
          // Fill + border, Slack-style: a low-alpha neutral chip when you
          // haven't reacted, an accent-tinted chip with a solid accent edge
          // when you have. Hover/focus deepens the fill and border a step.
          final Color fill;
          final Color borderColor;
          if (mine) {
            fill = context.colour.accentBackground;
            // Softer than a solid accent edge — enough to read as "yours"
            // without the chip shouting.
            borderColor = accent.withValues(alpha: boosted ? 0.7 : 0.5);
          } else {
            // Keep the light-mode fill near-white so the colored emoji stays
            // vibrant (a heavier gray tint visibly washes it out); the chip is
            // defined by its border, not its fill. Dark mode reads fine with a
            // slightly stronger neutral wash.
            fill = neutralInk.withValues(
              alpha: isLight
                  ? (boosted ? 0.07 : 0.035)
                  : (boosted ? 0.12 : 0.07),
            );
            // The theme border token already reads as Slack's ~13% chip edge;
            // lift it a touch on hover.
            borderColor = boosted
                ? neutralInk.withValues(alpha: isLight ? 0.28 : 0.20)
                : colors.border;
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            // Right margin keeps adjacent pill borders from touching; the
            // leading inset aligns the first pill's border with the content.
            margin: EdgeInsets.only(left: leadingInset, right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: borderColor, width: 1),
              // Rounded rectangle, not a full stadium — matches Slack's chip.
              borderRadius: BorderRadius.circular(8),
            ),
            child: child,
          );
        },
        child: content,
      ),
    );
  }
}
