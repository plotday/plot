import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/theme.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/logo_image.dart';

/// A compact representation of a contact.
///
/// Renders as a circle. If an avatar image is available it fills the circle;
/// otherwise it falls back to two-letter initials on a tinted background.
/// Tints are derived from a hash of the contact's identity, so avatars stay
/// scannable without pulling attention from titles.
///
/// Sizes itself from the ambient `IconTheme` so it matches sibling icons in
/// the same row (e.g. inside `FButton.icon`).
class Avatar extends StatelessWidget {
  const Avatar({
    this.actor,
    this.actorId,
    this.name,
    this.email,
    this.avatarUrl,
    this.size,
    this.tooltip = true,
    super.key,
  }) : assert(
         actor != null || actorId != null || email != null || name != null,
         'Avatar requires an actor, actorId, email, or name',
       );

  final Actor? actor;
  final ActorId? actorId;
  final String? name;
  final String? email;
  final String? avatarUrl;

  /// Diameter of the avatar circle. Defaults to the ambient `IconTheme` size
  /// so the avatar matches sibling icons in the same row. Callers that want
  /// the avatar to fill a containing button (overlapping its icon padding)
  /// pass an explicit larger size.
  final double? size;

  /// Whether to wrap the avatar in a tooltip showing name/email.
  final bool tooltip;

  @override
  Widget build(BuildContext context) {
    if (actor != null) return _buildForActor(context, actor!);
    if (actorId != null) {
      final cached = Actor.fromCache(actorId!);
      if (cached != null) return _buildForActor(context, cached);
      return FutureBuilder<Actor>(
        future: Actor.getOne(actorId!),
        builder: (context, snapshot) => snapshot.hasData
            ? _buildForActor(context, snapshot.data!)
            : _placeholder(context),
      );
    }
    return _buildAvatar(
      context,
      displayName: name,
      email: email,
      avatarUrl: avatarUrl,
      seed: _seedFromString(email ?? name ?? ''),
    );
  }

  Widget _buildForActor(BuildContext context, Actor a) {
    if (a.id.isTwist) {
      final twist = TwistInstance.fromCache(a.id.toUuid());
      if (twist != null) return _buildForTwist(context, a, twist);
    }
    return _buildAvatar(
      context,
      displayName: a.name,
      email: a.email,
      avatarUrl: a.avatarUrl,
      seed: a.id.toBytes().last,
    );
  }

  Widget _buildForTwist(BuildContext context, Actor a, TwistInstance twist) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final logoUrl = isDark && twist.logoUrlDark != null
        ? twist.logoUrlDark
        : twist.logoUrl;
    final s = size ?? _avatarSize(context);
    final fallback = _buildAvatar(
      context,
      displayName: a.name,
      email: a.email,
      avatarUrl: a.avatarUrl,
      seed: a.id.toBytes().last,
    );
    final Widget logo = logoUrl != null
        ? LogoImage(url: logoUrl, size: s, fallback: fallback)
        : fallback;
    if (!tooltip || a.name == null || a.name!.isEmpty) return logo;
    return FTooltip(
      tipBuilder: (context, controller) => Text(a.name!),
      child: logo,
    );
  }

  Widget _buildAvatar(
    BuildContext context, {
    String? displayName,
    String? email,
    String? avatarUrl,
    required int seed,
  }) {
    final s = size ?? _avatarSize(context);
    final themeColor = ThemeColor(seed.abs() % 8);
    final colours = context.colour.colours;
    // Foreground (initials) shares the bg's hue but is darker in light mode
    // and lighter in dark mode, so contrast is consistent across themes.
    final styleDelta = FAvatarStyleDelta.delta(
      backgroundColor: colours.backgroundFromTheme(themeColor),
      textStyle: TextStyleDelta.delta(
        color: colours.fromTheme(themeColor, muted: true),
        fontSize: context.theme.typography.xs.fontSize,
      ),
    );

    final initials = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        _initialsFrom(name: displayName, email: email),
        softWrap: false,
        maxLines: 1,
      ),
    );

    final hasAvatarUrl = avatarUrl != null && avatarUrl.isNotEmpty;
    final Widget avatar = hasAvatarUrl
        ? FAvatar(
            image: NetworkImage(avatarUrl),
            size: s,
            style: styleDelta,
            fallback: initials,
            semanticsLabel: displayName ?? email,
          )
        : FAvatar.raw(size: s, style: styleDelta, child: initials);

    if (!tooltip) return avatar;
    final lines = <String>[
      if (displayName != null && displayName.isNotEmpty) displayName,
      if (email != null && email.isNotEmpty) email,
    ];
    if (lines.isEmpty) return avatar;
    return FTooltip(
      tipBuilder: (context, controller) => Text(lines.join('\n')),
      child: avatar,
    );
  }

  Widget _placeholder(BuildContext context) => FAvatar.raw(
    size: size ?? _avatarSize(context),
    style: FAvatarStyleDelta.delta(
      backgroundColor: context.colour.editableBackground,
    ),
    child: const SizedBox.shrink(),
  );
}

/// Avatar diameter derived from the ambient `IconTheme` so the avatar matches
/// the icons surrounding it (e.g. `FButton.icon`'s `iconSizes.lg`). Falls
/// back to the theme's base icon size when no ambient size is available.
double _avatarSize(BuildContext context) {
  final iconSize = IconTheme.of(context).size;
  if (iconSize != null && iconSize > 0) return iconSize;
  return context.theme.iconSizes.base;
}

/// A compact row of [Avatar]s representing a set of contacts.
///
/// Shows up to [maxVisible] avatars overlapping horizontally. If
/// [totalCount] exceeds the number of visible avatar slots, the last slot
/// becomes a "+N" counter indicating how many contacts are hidden.
class AvatarGroup extends StatelessWidget {
  const AvatarGroup({
    required this.actors,
    this.totalCount,
    this.maxVisible = 3,
    this.size,
    super.key,
  }) : assert(maxVisible >= 1);

  /// Actors to show avatars for, in display order. If more actors are provided
  /// than fit, extra ones are rolled into the overflow badge.
  final List<Actor> actors;

  /// Total count across all shared targets, including things not represented
  /// by [actors] (e.g. groups, pending email invites). Defaults to
  /// [actors.length].
  final int? totalCount;
  final int maxVisible;

  /// Diameter of each avatar circle. Defaults to the ambient `IconTheme` size
  /// so the group matches sibling icons in the same row.
  final double? size;

  @override
  Widget build(BuildContext context) {
    final size = this.size ?? _avatarSize(context);
    final total = totalCount ?? actors.length;
    if (total <= 0) return SizedBox(width: 0, height: size);

    final hasOverflow = total > maxVisible;
    final avatarSlotLimit = hasOverflow
        ? maxVisible - 1
        : total.clamp(0, maxVisible);
    final visible = actors.take(avatarSlotLimit).toList();
    final visibleCount = visible.length;
    // Size from what we actually render: `total` can exceed `actors.length`
    // when shared targets include groups or pending email invites (we have a
    // count but no Actor to draw). Without this, the SizedBox reserves space
    // for slots that never get filled, leaving blank space at the right.
    final overflowCount = hasOverflow ? total - visibleCount : 0;
    final totalSlots = visibleCount + (hasOverflow ? 1 : 0);

    // Overlap is sized so the centered initials of each avatar stay fully
    // visible: each avatar must show enough of its left side to expose the
    // text. Worst case is "+NN" (overflow) or two-char initials at the
    // resolved FAvatar text size. We use the wider of the two as an upper
    // bound on the rendered text width and add a 2px margin so the next
    // avatar's edge never touches a glyph.
    final textStyle = const FAvatarStyleDelta.context()(
      context.theme.avatarStyle,
    ).textStyle;
    final fontSize = textStyle.fontSize ?? 14.0;
    final maxChars = overflowCount > 9 ? 3 : 2;
    final textHalfWidth = fontSize * 0.6 * maxChars / 2;
    final minStep = (size / 2 + textHalfWidth + 2.0).clamp(size / 2, size);

    final step = minStep;
    final totalWidth = totalSlots == 0 ? 0.0 : (totalSlots - 1) * step + size;

    final ringColor = context.colour.background;

    // Build right-to-left so leftmost avatars sit on top of those to their
    // right (later Stack children paint above earlier ones).
    final children = <Widget>[
      if (hasOverflow)
        Positioned(
          left: visibleCount * step,
          child: _Ring(
            size: size,
            color: ringColor,
            child: _OverflowBadge(size: size, count: overflowCount),
          ),
        ),
      for (var i = visible.length - 1; i >= 0; i--)
        Positioned(
          left: i * step,
          child: _Ring(
            size: size,
            color: ringColor,
            child: Avatar(actor: visible[i], size: size),
          ),
        ),
    ];

    return SizedBox(
      width: totalWidth,
      height: size,
      child: Stack(
        alignment: Alignment.centerLeft,
        clipBehavior: Clip.none,
        children: children,
      ),
    );
  }
}

/// A thin ring painted in the surrounding background color, giving overlapping
/// avatars a clean visual separation without altering layout width.
class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.color, required this.child});

  final double size;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size / 2);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: color, width: 1.2),
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}

class _OverflowBadge extends StatelessWidget {
  const _OverflowBadge({required this.size, required this.count});

  final double size;
  final int count;

  @override
  Widget build(BuildContext context) => FAvatar.raw(
    size: size,
    style: FAvatarStyleDelta.delta(
      backgroundColor: context.colour.editableBackground,
    ),
    child: Text('+$count'),
  );
}

/// Returns up to two characters for the avatar monogram. Single-word names
/// use the first two letters of the word with the second lowercased (e.g.
/// "Joe" -> "Jo", "Margo" -> "Ma"). Multi-word names use the first letter
/// of the first two words, both uppercase (e.g. "Stephen Cross" -> "SC").
/// Falls back to "?" when no usable characters are available.
String _initialsFrom({String? name, String? email}) {
  String source;
  if (name != null && name.trim().isNotEmpty) {
    source = name.trim();
  } else if (email != null && email.trim().isNotEmpty) {
    source = email.split('@').first.trim();
  } else {
    return '?';
  }

  final words = source
      .split(RegExp(r'[\s\-._]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';

  final letterRe = RegExp(r'[\p{L}\p{N}]', unicode: true);

  if (words.length == 1) {
    final matches = letterRe.allMatches(words[0]).toList();
    if (matches.isEmpty) return '?';
    final first = matches[0].group(0)!.toUpperCase();
    if (matches.length < 2) return first;
    return '$first${matches[1].group(0)!.toLowerCase()}';
  }

  final firstMatch = letterRe.firstMatch(words[0]);
  if (firstMatch == null) return '?';
  final first = firstMatch.group(0)!.toUpperCase();
  final secondMatch = letterRe.firstMatch(words[1]);
  if (secondMatch == null) return first;
  return '$first${secondMatch.group(0)!.toUpperCase()}';
}

int _seedFromString(String s) {
  var hash = 0;
  for (final code in s.codeUnits) {
    hash = (hash * 31 + code) & 0x7FFFFFFF;
  }
  return hash;
}
