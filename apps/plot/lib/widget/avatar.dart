import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';
import 'logging.dart';

/// A widget that displays an actor's avatar image or initials.
///
/// Shows the actor's avatar image if [avatarUrl] is available,
/// otherwise displays initials extracted from the actor's name.
///
/// Can accept either an [Actor] directly or an [ActorId] to load asynchronously.
/// Exactly one of [actor] or [actorId] must be provided.
class Avatar extends StatelessWidget {
  const Avatar({this.actor, this.actorId, this.size, super.key})
    : assert(
        (actor != null) != (actorId != null),
        'Exactly one of actor or actorId must be provided',
      );

  /// Direct actor instance to display
  final Actor? actor;

  /// Actor ID to load asynchronously
  final ActorId? actorId;

  final double? size;

  /// Extracts initial from a name (first character, uppercase).
  static String _getInitials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }

  /// Hashes an email address to an integer for color assignment
  static int _hashEmail(String? email) {
    if (email == null || email.isEmpty) return 0;
    final bytes = utf8.encode(email.toLowerCase());
    int hash = 0;
    for (var byte in bytes) {
      hash = ((hash << 5) - hash) + byte;
      hash = hash & 0xFFFFFFFF; // Convert to 32-bit integer
    }
    return hash.abs();
  }

  @override
  Widget build(BuildContext context) {
    final avatarSize = size ?? context.theme.iconSizes.base;

    // If actorId is provided, load actor asynchronously
    if (actorId != null) {
      return FutureBuilder<Actor?>(
        future: _loadActor(actorId!),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            // Show placeholder icon while loading
            return Icon(FontAwesomeIcons.user, size: avatarSize);
          }

          final loadedActor = snapshot.data;
          if (loadedActor == null) {
            // Show fallback avatar if actor not found
            return _buildFallbackAvatar(context, avatarSize);
          }

          return _buildAvatar(context, loadedActor, avatarSize);
        },
      );
    }

    // If actor is provided directly, render immediately
    return _buildAvatar(context, actor!, avatarSize);
  }

  /// Load actor from database by ID
  Future<Actor?> _loadActor(ActorId id) async {
    try {
      return await Actor.getOne(id);
    } catch (e) {
      // Actor not found or error loading
      return null;
    }
  }

  /// Build the avatar widget for a given actor
  Widget _buildAvatar(BuildContext context, Actor actor, double size) {
    if (actor.avatarUrl != null && actor.avatarUrl!.isNotEmpty) {
      return FAvatar(image: NetworkImage(actor.avatarUrl!), size: size);
    }

    // Hash the email to determine colors
    final hash = _hashEmail(actor.email);
    final borderColorIndex = hash % 8;
    final textColorIndex = (hash % 64) ~/ 8;
    log.fine(
      'Avatar colors for actor ${actor.id.value}: '
      'borderColorIndex=$borderColorIndex, textColorIndex=$textColorIndex',
    );

    // Get the color scheme to generate colors from ThemeColor
    final colorScheme = context.colour;
    final borderColor = colorScheme.colours.fromTheme(
      ThemeColor(borderColorIndex),
    );
    final textColor = colorScheme.colours.fromTheme(ThemeColor(textColorIndex));

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 1),
      ),
      child: FAvatar.raw(
        size: size,
        child: Center(
          child: Text(
            _getInitials(actor.name),
            style: context.theme.typography.base.copyWith(
              fontSize: size * 0.7, // Scale text to fit avatar
              fontWeight: FontWeight.w600,
              height: 1.0,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  /// Build a fallback avatar when actor is not found
  Widget _buildFallbackAvatar(BuildContext context, double size) {
    // Use default theme color for fallback
    final colorScheme = context.colour;
    final defaultColor = colorScheme.colours.fromTheme(
      const ThemeColor.defaultColor(),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: defaultColor, width: 1),
      ),
      child: FAvatar.raw(
        size: size,
        child: Text(
          '?',
          style: context.theme.typography.base.copyWith(
            fontSize: size * 0.8,
            fontWeight: FontWeight.w600,
            color: defaultColor,
          ),
        ),
      ),
    );
  }
}
