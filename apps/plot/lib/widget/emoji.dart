import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/widget/emoji_data.g.dart';

/// Human-readable display label for an emoji: the CLDR name with its first
/// letter capitalized (e.g. `"😂"` → `"Face with tears of joy"`). Falls back
/// to the raw emoji string when no name is known (custom-emoji refs etc.).
String emojiDisplayName(Reaction emoji) {
  final name = kUnicodeEmojiNames[emoji];
  if (name == null || name.isEmpty) return emoji;
  return '${name[0].toUpperCase()}${name.substring(1)}';
}

/// Renders an emoji [Reaction] string — either a Unicode grapheme cluster
/// (e.g. `"👍"`) or a provider-scoped custom-emoji ref (e.g.
/// `"slack:T01/party_parrot"`).
///
/// Unicode emoji render via the bundled Noto Color Emoji font for cross-OS
/// visual consistency — the same colorful glyphs appear on every platform
/// instead of each OS's native emoji set.
///
/// Custom-emoji refs are rendered via [Image.network] against the cached
/// `image_url` from `custom_emoji`. When the cache misses, the raw emoji
/// string is rendered as a fallback so the user still sees something
/// (typically the shortcode form).
class EmojiText extends StatelessWidget {
  const EmojiText(
    this.emoji, {
    this.size = 16,
    super.key,
  });

  /// The reaction value: a Unicode grapheme cluster or a custom-emoji ref.
  final Reaction emoji;

  /// Visual size of the emoji in logical pixels.
  final double size;

  /// Font family registered in pubspec.yaml. See class doc for rationale.
  static const String _fontFamily = 'NotoColorEmoji';

  @override
  Widget build(BuildContext context) {
    if (isCustomEmojiRef(emoji)) {
      return _CustomEmojiImage(refId: emoji, size: size);
    }
    // No fontFamilyFallback: keep rendering pinned to the bundled font so
    // reactions look the same on every OS. Noto Color Emoji covers the
    // entire Unicode 15.1 spec, so missing glyphs are rare; for them,
    // Flutter's default platform chain still picks up the system emoji
    // font as a last resort.
    return Text(
      emoji,
      style: TextStyle(
        fontFamily: _fontFamily,
        fontSize: size,
        height: 1.0,
      ),
      // Single-line; emoji shouldn't wrap.
      maxLines: 1,
      softWrap: false,
    );
  }
}

/// Renders a custom-emoji ref by looking it up in the local `custom_emoji`
/// cache (populated by `/sync/custom-emoji`).
class _CustomEmojiImage extends StatelessWidget {
  const _CustomEmojiImage({required this.refId, required this.size});

  final String refId;
  final double size;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CustomEmojiRow?>(
      future: _lookup(refId),
      builder: (context, snapshot) {
        final row = snapshot.data;
        if (row == null) {
          // Cache miss (or still loading) — fall back to the raw refId so
          // the user sees something instead of an invisible chip. The most
          // recognizable part of a Slack ref is the trailing `/name`; show
          // just that.
          final name = refId.contains('/')
              ? ':${refId.substring(refId.lastIndexOf('/') + 1)}:'
              : refId;
          return Text(
            name,
            style: TextStyle(fontSize: size * 0.75, height: 1.0),
            maxLines: 1,
            softWrap: false,
          );
        }
        return Image.network(
          row.imageUrl,
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return Text(
              ':${row.name}:',
              style: TextStyle(fontSize: size * 0.75, height: 1.0),
              maxLines: 1,
              softWrap: false,
            );
          },
        );
      },
    );
  }

  static Future<CustomEmojiRow?> _lookup(String refId) async {
    if (!Store.isAvailable) return null;
    // Follow aliases one hop so aliased Slack emoji render the canonical
    // image. Two-hop chains are rare; the cache is the cheap path so we
    // stop after the first redirect.
    final row = await (Store.get.select(Store.get.customEmojis)
          ..where((t) => t.id.equals(refId)))
        .getSingleOrNull();
    if (row == null) return null;
    final aliasOf = row.aliasOf;
    if (aliasOf != null && aliasOf != refId) {
      final aliasedRow = await (Store.get.select(Store.get.customEmojis)
            ..where((t) => t.id.equals(aliasOf)))
          .getSingleOrNull();
      return aliasedRow ?? row;
    }
    return row;
  }
}

/// Square emoji icon sized to the theme's `iconSizes.base`. Color emoji
/// paint within their line box, so the glyph sits at the icon size with no
/// scaling — visually equivalent to a neighboring icon. Use this anywhere a
/// [Command.icon] would normally sit (filter rows, hover toolbar, picker
/// chips).
class EmojiCommandIcon extends StatelessWidget {
  const EmojiCommandIcon(this.emoji, {super.key});

  final Reaction emoji;

  @override
  Widget build(BuildContext context) {
    final iconSize = context.theme.iconSizes.base;
    return SizedBox(
      width: iconSize,
      height: iconSize,
      child: Center(
        child: EmojiText(emoji, size: iconSize),
      ),
    );
  }
}
