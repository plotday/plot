import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/theme.dart';
import 'package:plot/store/store.dart';
import 'package:plot/style/colors.dart';
import 'package:plot/style/plot_icon_sizes.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/widget/icon.dart';
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
    if (actor != null) {
      // Prefer the canonical (primary) actor so a user with multiple
      // linked-contact aliases always renders with their primary identity.
      final canonicalId = Actor.canonicalId(actor!.id);
      if (canonicalId != actor!.id) {
        final canonical = Actor.fromCache(canonicalId);
        if (canonical != null) return _buildForActor(context, canonical);
      }
      return _buildForActor(context, actor!);
    }
    if (actorId != null) {
      final canonicalId = Actor.canonicalId(actorId!);
      final cached = Actor.fromCache(canonicalId);
      if (cached != null) return _buildForActor(context, cached);
      return FutureBuilder<Actor>(
        future: Actor.getOne(canonicalId),
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

    final initials = _CenteredInitials(
      text: _initialsFrom(name: displayName, email: email),
      diameter: s,
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

/// Paints avatar initials (or an `+N` overflow count) on a fixed, cap-centered
/// baseline so every avatar — crucially the ones sharing an [AvatarGroup] —
/// aligns on the same baseline.
///
/// The baseline is anchored so that capital letters are vertically centered in
/// the circle. Because that anchor depends only on the font size (never on
/// which glyphs are drawn or how wide they are), all avatars share it; lowercase
/// letters simply sit on the same baseline and so descend lower, by design.
///
/// Wide glyph pairs (e.g. "MW") are squeezed *horizontally only* to fit — never
/// uniformly scaled — so fitting can't shift the baseline. (A uniform
/// `FittedBox.scaleDown` would shrink the box vertically and re-center it,
/// nudging the baseline up for wide pairs and leaving narrow ones in place —
/// the exact inconsistency this widget removes.)
class _CenteredInitials extends StatelessWidget {
  const _CenteredInitials({required this.text, required this.diameter});

  final String text;
  final double diameter;

  /// Figtree's cap height as a fraction of the em (capHeight 700 / unitsPerEm
  /// 1000). The app renders avatars in Figtree only, so a constant is exact.
  static const double _capHeightEm = 0.7;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(diameter),
      painter: _InitialsPainter(
        text: text,
        style: DefaultTextStyle.of(context).style,
        capHeightEm: _capHeightEm,
      ),
    );
  }
}

class _InitialsPainter extends CustomPainter {
  _InitialsPainter({
    required this.text,
    required this.style,
    required this.capHeightEm,
  });

  final String text;
  final TextStyle style;
  final double capHeightEm;

  @override
  void paint(Canvas canvas, Size size) {
    final fontSize = style.fontSize ?? 14.0;
    final painter = TextPainter(
      // `height: 1` gives a tight, predictable line box; the baseline is then
      // anchored explicitly below, so the leading distribution is irrelevant.
      text: TextSpan(text: text, style: style.copyWith(height: 1)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    // Anchor the alphabetic baseline so capitals are centered: a capital rises
    // `capHeight` above the baseline, so placing the baseline capHeight/2 below
    // the circle's center centers the capital. This y depends only on fontSize,
    // so it is identical for every avatar — which is what keeps a group's
    // avatars on a common baseline.
    final baselineY = size.height / 2 + (fontSize * capHeightEm) / 2;

    final metrics = painter.computeLineMetrics();
    final baselineFromTop =
        metrics.isNotEmpty ? metrics.first.baseline : painter.height;

    // Squeeze horizontally (never vertically) when a wide pair would otherwise
    // touch the ring, so the baseline stays put. The small margin keeps glyphs
    // off the circle's curved edge.
    final maxWidth = size.width * 0.84;
    final scaleX = painter.width > maxWidth ? maxWidth / painter.width : 1.0;
    final dx = (size.width - painter.width * scaleX) / 2;
    final dy = baselineY - baselineFromTop;

    canvas.save();
    canvas.translate(dx, dy);
    if (scaleX != 1.0) canvas.scale(scaleX, 1);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InitialsPainter old) =>
      old.text != text ||
      old.style != style ||
      old.capHeightEm != capHeightEm;
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
///
/// A single tooltip wraps the entire group rather than each avatar, listing
/// contacts (with RSVP icons when [scheduleContacts] is provided) sorted
/// attending → declined → tentative/unknown.
///
/// A subtle outline traces the union silhouette of the circles. When
/// [clickable] is set it brightens on hover to signal the tap affordance.
class AvatarGroup extends StatelessWidget {
  const AvatarGroup({
    required this.actors,
    this.totalCount,
    this.maxVisible = 3,
    this.size,
    this.scheduleContacts,
    this.tooltipBelow = false,
    this.clickable = false,
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

  /// When non-null and non-empty, the tooltip lists each contact with a
  /// check / X / question icon for their RSVP, sorted attending first,
  /// declined next, then tentative/unknown. When null or empty, the tooltip
  /// falls back to a plain list of actor names.
  final List<ScheduleContact>? scheduleContacts;

  /// Anchor the hover tooltip below the group instead of above. Use when
  /// the group sits at the top of a clipped container.
  final bool tooltipBelow;

  /// Whether the group acts as a tap target (the tap itself is owned by an
  /// ancestor, e.g. a button). When true, the subtle outline brightens on
  /// hover to signal the affordance; when false the outline stays static.
  final bool clickable;

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
    // right (later Stack children paint above earlier ones). Per-avatar
    // tooltips are disabled so the unified group tooltip below is the only
    // hover affordance.
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
            child: Avatar(actor: visible[i], size: size, tooltip: false),
          ),
        ),
    ];

    final stack = SizedBox(
      width: totalWidth,
      height: size,
      child: Stack(
        alignment: Alignment.centerLeft,
        clipBehavior: Clip.none,
        children: children,
      ),
    );

    // A single subtle outline tracing the union silhouette of the avatar
    // circles (so it follows their curve rather than boxing the group in a
    // rectangle). When the group is clickable it brightens on hover.
    final outlined = _GroupOutline(
      slots: totalSlots,
      step: step,
      size: size,
      restColor: context.colour.border,
      hoverColor: context.colour.muted,
      clickable: clickable,
      child: stack,
    );

    final tooltipBuilder = _tooltipBuilder(context);
    if (tooltipBuilder == null) return outlined;
    return FTooltip(
      tipAnchor: tooltipBelow ? Alignment.topCenter : Alignment.bottomCenter,
      childAnchor: tooltipBelow ? Alignment.bottomCenter : Alignment.topCenter,
      tipBuilder: tooltipBuilder,
      child: outlined,
    );
  }

  /// Builds a single tooltip for the whole group. When [scheduleContacts] is
  /// provided, lists each contact with a check / X / question icon for their
  /// RSVP (attending → declined → tentative/unknown). Otherwise lists the
  /// names of actors that have one. Returns null when neither source has
  /// anything worth showing.
  Widget Function(BuildContext, FTooltipController)? _tooltipBuilder(
    BuildContext context,
  ) {
    final contacts = scheduleContacts;
    if (contacts != null && contacts.isNotEmpty) {
      return (context, controller) => RsvpDetails(contacts: contacts);
    }

    final visible = [
      for (final a in actors)
        if ((a.name != null && a.name!.isNotEmpty) ||
            (a.email != null && a.email!.isNotEmpty))
          a,
    ];
    if (visible.isEmpty) return null;
    return (context, controller) => _ActorListTooltipContent(actors: visible);
  }
}

class _ActorListTooltipContent extends StatelessWidget {
  const _ActorListTooltipContent({required this.actors});

  final List<Actor> actors;

  @override
  Widget build(BuildContext context) {
    final textStyle = context.theme.typography.sm;
    final mutedStyle = textStyle.copyWith(color: context.colour.muted);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final a in actors)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: _actorLabel(a, textStyle, mutedStyle),
          ),
      ],
    );
  }

  Widget _actorLabel(Actor a, TextStyle textStyle, TextStyle mutedStyle) {
    final hasName = a.name != null && a.name!.isNotEmpty;
    final hasEmail = a.email != null && a.email!.isNotEmpty;
    if (hasName && hasEmail) {
      return Text.rich(
        TextSpan(
          style: textStyle,
          children: [
            TextSpan(text: a.name),
            const TextSpan(text: '  '),
            TextSpan(text: a.email, style: mutedStyle),
          ],
        ),
      );
    }
    return Text(hasName ? a.name! : a.email!, style: textStyle);
  }
}

/// Grouped attendee details for an event RSVP. Sections (Going / Not going /
/// Undecided) appear only when non-empty; the current user's row(s) are
/// marked. Shown in the avatar-group tooltip and the RSVP chip's hover popover.
class RsvpDetails extends StatelessWidget {
  const RsvpDetails({required this.contacts, super.key});

  final List<ScheduleContact> contacts;

  /// Pure partition by status (testable without a render).
  ///
  /// When [userId] is provided, the current user's contact(s) are floated to
  /// the front of whichever group they land in (e.g. if they decline, they're
  /// first under "Not going"). A user may have multiple matching contacts
  /// (work + personal email), so all of them lead; remaining order is stable.
  static ({
    List<ScheduleContact> going,
    List<ScheduleContact> declined,
    List<ScheduleContact> undecided,
  })
  group(List<ScheduleContact> contacts, {String? userId}) {
    final going = <ScheduleContact>[];
    final declined = <ScheduleContact>[];
    final undecided = <ScheduleContact>[];
    for (final c in contacts) {
      switch (c.status) {
        case 'attend':
          going.add(c);
        case 'skip':
          declined.add(c);
        default:
          undecided.add(c);
      }
    }
    if (userId != null) {
      // Stable reorder: the user's contacts first, everyone else after.
      List<ScheduleContact> userFirst(List<ScheduleContact> people) => [
        ...people.where((c) => c.contactUserId == userId),
        ...people.where((c) => c.contactUserId != userId),
      ];
      return (
        going: userFirst(going),
        declined: userFirst(declined),
        undecided: userFirst(undecided),
      );
    }
    return (going: going, declined: declined, undecided: undecided);
  }

  @override
  Widget build(BuildContext context) {
    final userId = Base.userIdOrNull?.toString();
    final g = group(contacts, userId: userId);
    final textStyle = context.theme.typography.sm;
    final mutedStyle = textStyle.copyWith(color: context.colour.muted);
    final headerStyle = context.theme.typography.xs.copyWith(
      color: context.colour.veryMuted,
      letterSpacing: 0.3,
    );
    final youColor = context.colour.accent;

    final goingColor = context.colour.colours.fromTheme(
      const ThemeColor(0),
      muted: true,
    );
    final declinedColor = context.colour.colours.fromTheme(
      const ThemeColor(5),
      muted: true,
    );
    final undecidedColor = context.colour.veryMuted;

    Widget section(
      String label,
      IconData icon,
      Color color,
      List<ScheduleContact> people,
    ) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FaIcon(
                  icon,
                  size: (headerStyle.fontSize ?? 11) * 0.9,
                  color: color,
                ),
                const SizedBox(width: 5),
                Text(
                  '${label.toUpperCase()} · ${people.length}',
                  style: headerStyle,
                ),
              ],
            ),
          ),
          for (final c in people)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: _contactLabel(
                c,
                textStyle,
                mutedStyle,
                isUser: userId != null && c.contactUserId == userId,
                youColor: youColor,
              ),
            ),
        ],
      );
    }

    final sections = <Widget>[
      if (g.going.isNotEmpty)
        section('Going', PlotIcon.rsvpGoing, goingColor, g.going),
      if (g.declined.isNotEmpty)
        section('Not going', PlotIcon.rsvpDeclined, declinedColor, g.declined),
      if (g.undecided.isNotEmpty)
        section(
          'Undecided',
          PlotIcon.rsvpUndecided,
          undecidedColor,
          g.undecided,
        ),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      // 6px between sections; none before the first so the popover hugs its content.
      spacing: 6,
      children: sections,
    );
  }

  Widget _contactLabel(
    ScheduleContact c,
    TextStyle textStyle,
    TextStyle mutedStyle, {
    required bool isUser,
    required Color youColor,
  }) {
    final hasName = c.contactName != null && c.contactName!.isNotEmpty;
    final hasEmail = c.contactEmail != null && c.contactEmail!.isNotEmpty;
    // The current user reads as "You <email>"; everyone else as "<name> <email>".
    final name = isUser
        ? 'You'
        : (hasName ? c.contactName! : (hasEmail ? c.contactEmail! : 'Unknown'));
    // Show the email alongside unless the label already is the email.
    final showEmail = hasEmail && name != c.contactEmail;
    return Text.rich(
      TextSpan(
        style: textStyle,
        children: [
          TextSpan(
            text: name,
            style: isUser ? textStyle.copyWith(color: youColor) : null,
          ),
          if (showEmail) ...[
            const TextSpan(text: '  '),
            TextSpan(text: c.contactEmail, style: mutedStyle),
          ],
        ],
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

/// Overlays a subtle outline around the union silhouette of the avatar
/// circles, so the border follows their curve rather than boxing the group in
/// a rectangle. When [clickable] is set the outline brightens on hover as an
/// affordance; the tap itself is handled by an ancestor.
class _GroupOutline extends StatefulWidget {
  const _GroupOutline({
    required this.slots,
    required this.step,
    required this.size,
    required this.restColor,
    required this.hoverColor,
    required this.clickable,
    required this.child,
  });

  /// Number of circles in the group (visible avatars plus the overflow badge).
  final int slots;

  /// Horizontal distance between adjacent circle centers.
  final double step;

  /// Diameter of each circle.
  final double size;

  final Color restColor;
  final Color hoverColor;
  final bool clickable;
  final Widget child;

  @override
  State<_GroupOutline> createState() => _GroupOutlineState();
}

class _GroupOutlineState extends State<_GroupOutline> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.clickable && _hovered
        ? widget.hoverColor
        : widget.restColor;
    final painted = CustomPaint(
      foregroundPainter: _GroupOutlinePainter(
        slots: widget.slots,
        step: widget.step,
        size: widget.size,
        color: color,
      ),
      child: widget.child,
    );
    if (!widget.clickable) return painted;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: painted,
    );
  }
}

class _GroupOutlinePainter extends CustomPainter {
  const _GroupOutlinePainter({
    required this.slots,
    required this.step,
    required this.size,
    required this.color,
  });

  final int slots;
  final double step;
  final double size;
  final Color color;

  /// Outline stroke width. Kept thin so the border stays subtle.
  static const double _stroke = 1.0;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (slots <= 0) return;
    final r = size / 2;
    // Trace circles inset by half the stroke so the stroke's outer edge lands
    // exactly on each avatar's outer edge and never spills past the group's
    // bounds (where a parent might clip it).
    final pr = r - _stroke / 2;
    // Use dart:ui's Path explicitly: `package:plot/util/path.dart` (re-exported
    // transitively via store.dart) defines its own `Path`, which would
    // otherwise shadow the painting one.
    var union = ui.Path()
      ..addOval(Rect.fromCircle(center: Offset(r, r), radius: pr));
    for (var i = 1; i < slots; i++) {
      final circle = ui.Path()
        ..addOval(Rect.fromCircle(center: Offset(r + i * step, r), radius: pr));
      // Union so only the outer silhouette is stroked; overlaps between
      // adjacent circles produce a concave notch that follows their curve.
      union = ui.Path.combine(PathOperation.union, union, circle);
    }
    canvas.drawPath(
      union,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_GroupOutlinePainter old) =>
      old.slots != slots ||
      old.step != step ||
      old.size != size ||
      old.color != color;
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
      textStyle: TextStyleDelta.delta(
        fontSize: context.theme.typography.xs.fontSize,
      ),
    ),
    // Shares the initials' baseline anchoring so the counter sits on the same
    // baseline as the sibling avatars' initials (multi-digit counts like "+150"
    // are squeezed horizontally, never vertically).
    child: _CenteredInitials(text: '+$count', diameter: size),
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
