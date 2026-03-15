import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import 'package:plot/store/store.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/util/theme_color.dart';
import 'logging.dart';

/// A widget that displays an actor's initials.
///
/// Displays up to 3 initials extracted from the actor's name, with each
/// character potentially having a different color based on the actor's email hash.
///
/// Can accept either an [Actor] directly or an [ActorId] to load asynchronously.
/// Exactly one of [actor] or [actorId] must be provided.
class Initials extends StatelessWidget {
  const Initials({
    this.actor,
    this.actorId,
    this.size,
    this.fallback = '?',
    super.key,
  }) : assert(
         (actor != null) != (actorId != null),
         'Exactly one of actor or actorId must be provided',
       );

  /// Direct actor instance to display
  final Actor? actor;

  /// Actor ID to load asynchronously
  final ActorId? actorId;

  final double? size;
  final String? fallback;

  /// Extracts up to 3 initials from a name or email.
  /// If name is provided, splits by spaces or dashes.
  /// If only email is provided, extracts from the local part (before @).
  static String _getInitials(String? name, String? email) {
    String source;

    // Use name if available, otherwise extract from email
    if (name != null && name.trim().isNotEmpty) {
      source = name.trim();
    } else if (email != null && email.trim().isNotEmpty) {
      // Extract local part from email (before @)
      source = email.split('@').first.trim();
    } else {
      return '?';
    }

    // Split by space, dash, dot, or underscore
    final words = source.split(RegExp(r'[\s\-._]+'));

    // Take first character of each word, up to 3 words
    final initials = words
        .where((word) => word.isNotEmpty)
        .take(3)
        .map((word) => word.substring(0, 1).toUpperCase())
        .join('');

    return initials.isEmpty ? '?' : initials;
  }

  /// Gets a color for a specific character position based on email hash
  int _getCharacterColorIndex(int charIndex) {
    return ((actor?.id ?? actorId)!.toBytes().last >> charIndex) % 8;
  }

  @override
  Widget build(BuildContext context) {
    final initialsSize = size ?? context.theme.iconSizes.base;

    // If actorId is provided, load actor asynchronously
    if (actorId != null) {
      return FutureBuilder<Actor?>(
        future: _loadActor(actorId!),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return _buildFallbackInitials(context, initialsSize);
          }

          final loadedActor = snapshot.data;
          if (loadedActor == null) {
            // Show fallback initials if actor not found
            return _buildFallbackInitials(context, initialsSize);
          }

          return _buildInitials(context, loadedActor, initialsSize);
        },
      );
    }

    // If actor is provided directly, render immediately
    return _buildInitials(context, actor!, initialsSize);
  }

  /// Load actor from database by ID
  Future<Actor?> _loadActor(ActorId id) async {
    try {
      return await Actor.getOne(id);
    } catch (e, t) {
      log.warning('Error loading actor with id $id', e, t);
      return null;
    }
  }

  /// Build the initials widget for a given actor
  Widget _buildInitials(BuildContext context, Actor actor, double size) {
    final initials = _getInitials(actor.name, actor.email);
    final colorScheme = context.colour;

    // Create a Text widget for each character with its own color
    final children = <Widget>[];
    for (int i = 0; i < initials.length; i++) {
      final colorIndex = _getCharacterColorIndex(i);
      final color = colorScheme.colours.fromTheme(ThemeColor(colorIndex));

      children.add(
        Text(
          initials[i],
          style: context.theme.typography.md.copyWith(
            fontSize: size,
            fontWeight: FontWeight.w600,
            height: 1.0,
            color: color,
          ),
        ),
      );
    }

    final initialsWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );

    // Build tooltip text: name (if available) and email
    final tooltipLines = <String>[];
    if (actor.name != null && actor.name!.isNotEmpty) {
      tooltipLines.add(actor.name!);
    }
    if (actor.email != null && actor.email!.isNotEmpty) {
      tooltipLines.add(actor.email!);
    }

    // Wrap in tooltip if we have tooltip content
    if (tooltipLines.isNotEmpty) {
      return FTooltip(
        tipBuilder: (context, controller) => Text(tooltipLines.join('\n')),
        child: initialsWidget,
      );
    }

    return initialsWidget;
  }

  /// Build fallback initials when actor is not found
  Widget _buildFallbackInitials(BuildContext context, double size) {
    return fallback != null
        ? Text(
            fallback!,
            style: context.theme.typography.md.copyWith(
              fontSize: size,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          )
        : SizedBox.shrink();
  }
}
