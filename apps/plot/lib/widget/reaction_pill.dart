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
    // Accent when the user reacted; neutral otherwise. The base opacity is
    // identical either way — only the hue changes — so "mine" reads as a
    // tint, not a heavier chip. Hover/focus boosts the contrast.
    final tint = mine ? context.colour.accent : colors.mutedForeground;
    final countColor = mine ? context.colour.accent : context.colour.muted;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EmojiCommandIcon(emoji),
        if (count > 1) ...[
          const SizedBox(width: 4),
          Text(
            '$count',
            style: context.theme.typography.xs.copyWith(
              color: countColor,
              height: 1,
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
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            // Right margin keeps adjacent pill borders from touching; the
            // leading inset aligns the first pill's border with the content.
            margin: EdgeInsets.only(left: leadingInset, right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: boosted ? 0.12 : 0.05),
              border: Border.all(
                color: tint.withValues(alpha: boosted ? 0.5 : 0.25),
              ),
              borderRadius: BorderRadius.circular(999),
            ),
            child: child,
          );
        },
        child: content,
      ),
    );
  }
}
