import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';
import 'package:prism_flutter/prism_flutter.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/style/colors.dart' show ColourSchemeExtension;
import 'package:plot/store/store.dart' show Actor, GroupRow, Priority;
import 'package:plot/widget/avatar.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/priority.dart';

// ─── Layout constants ────────────────────────────────────────────────────────

/// Fixed leading-glyph gutter shared by every pill variant. Sized to the widest
/// glyph (the 24px avatar / count badge); narrower glyphs — logos, focus and
/// twist icons — are centred within it, so every row's name starts at the same
/// x and the glyphs line up on a single vertical centreline.
const double composePillGutter = 24;

/// Gap between the leading-glyph gutter and the name.
const double composePillIconGap = 8;

/// Size of the smaller leading glyphs — connector/twist logos and focus icons.
/// Matches the thread list's logo size, sitting centred within the wider
/// [composePillGutter] (which is sized to the 24px avatars / count badges).
const double composePillLogoSize = 16;

// ─── Data model ──────────────────────────────────────────────────────────────

/// What a [ComposePill] renders. Sealed so the widget switches exhaustively.
sealed class ComposePillData {
  const ComposePillData();
}

/// A single person: avatar + name + email.
class ContactPillData extends ComposePillData {
  const ContactPillData(this.actor);
  final Actor actor;
}

/// A formal group: count badge + name + truncated member emails. Tooltip lists
/// all member names + addresses.
class GroupPillData extends ComposePillData {
  const GroupPillData(this.group, this.members);
  final GroupRow group;
  final List<Actor> members;
}

/// A recent ad-hoc combo of multiple contacts (no formal group): count badge +
/// truncated member names. Tooltip lists all names + addresses.
class AdHocGroupPillData extends ComposePillData {
  const AdHocGroupPillData(this.actors, {this.inviteEmails = const []});
  final List<Actor> actors;
  final List<String> inviteEmails;
}

/// A non-connection twist (assistant): logo + name, in the same name colour as
/// the contact rows it shares the section with.
class TwistPillData extends ComposePillData {
  const TwistPillData(this.target);
  final ComposeTarget target; // kind == twist
}

/// A non-person connector destination: logo + connection name + channel.
class ChannelPillData extends ComposePillData {
  const ChannelPillData(this.target);
  final ComposeTarget target; // kind == connector, channel != null
}

/// A focus (private note): focus icon + name in focus colour.
class FocusPillData extends ComposePillData {
  const FocusPillData(this.priority);
  final Priority priority;
}

/// A step-2 connection option: logo + connection name + reach detail.
class ConnectionPillData extends ComposePillData {
  const ConnectionPillData(this.target, {this.label, this.detail});
  final ComposeTarget target; // chat (Plot) or connector DM
  final String? label;
  final String? detail;
}

// ─── Widget ──────────────────────────────────────────────────────────────────

/// Renders the inner content of a single compose target (person, group,
/// connection, focus, twist, or channel) as a single horizontal line: a leading
/// glyph (avatar / logo / count badge / focus icon), the name, and — when
/// present — an inline muted meta detail (email / channel / scope).
///
/// This is a pure content widget. The row chrome (full-width hit area, rounded
/// hover / selection highlight, tap handling) is supplied by the parent
/// ([PillGrid]); it can also be rendered bare as a static line (e.g. the chosen
/// recipient in the step-2 connection picker).
///
/// Group and ad-hoc entries are wrapped in an [FTooltip] listing all member
/// names and addresses.
class ComposePill extends StatelessWidget {
  const ComposePill({
    required this.data,
    super.key,
  });

  final ComposePillData data;

  @override
  Widget build(BuildContext context) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final content = _buildContent(context, isDark);

    return switch (data) {
      GroupPillData(:final members) => _withTooltip(
          context,
          members.map(_formatActorLine).toList(),
          content,
        ),
      AdHocGroupPillData(:final actors, :final inviteEmails) => _withTooltip(
          context,
          [...actors.map(_formatActorLine), ...inviteEmails],
          content,
        ),
      _ => content,
    };
  }

  /// The single-line content for each variant: leading slot + name (+ inline
  /// meta). Each arm returns a full-width [Row]; the text region is wrapped in
  /// an [Expanded] so long names ellipsize within the row.
  Widget _buildContent(BuildContext context, bool isDark) {
    final colors = context.theme.colors;
    final nameStyle = context.theme.typography.md;
    final metaStyle = nameStyle.copyWith(color: colors.mutedForeground);

    return switch (data) {
      ContactPillData(:final actor) => Row(
          children: [
            _gutter(Avatar(actor: actor, size: 24, tooltip: false)),
            const SizedBox(width: composePillIconGap),
            Expanded(
              child: _nameMetaLine(
                name: actor.nameOrEmail,
                meta: actor.email,
                nameStyle: nameStyle,
                metaStyle: metaStyle,
              ),
            ),
          ],
        ),

      GroupPillData(:final group, :final members) => Row(
          children: [
            _gutter(_countBadge(context, members.length)),
            const SizedBox(width: composePillIconGap),
            Expanded(
              child: _nameMetaLine(
                name: group.name,
                meta: members.map((a) => a.email ?? a.nameOrEmail).join(', '),
                nameStyle: nameStyle,
                metaStyle: metaStyle,
              ),
            ),
          ],
        ),

      AdHocGroupPillData(:final actors, :final inviteEmails) => () {
          final total = actors.length + inviteEmails.length;
          final names = [
            ...actors.map((a) => a.nameOrEmail),
            ...inviteEmails,
          ].join(', ');
          // Email addresses listed comma-separated after the names (muted),
          // matching the member-email detail on a formal group row.
          final emails =
              actors.map((a) => a.email).whereType<String>().join(', ');
          return Row(
            children: [
              _gutter(_countBadge(context, total)),
              const SizedBox(width: composePillIconGap),
              Expanded(
                child: _nameMetaLine(
                  name: names,
                  meta: emails,
                  nameStyle: nameStyle,
                  metaStyle: metaStyle,
                ),
              ),
            ],
          );
        }(),

      TwistPillData(:final target) => () {
          final twist = target.connection;
          final logo = twist == null
              ? null
              : (isDark ? (twist.logoUrlDark ?? twist.logoUrl) : twist.logoUrl);
          return Row(
            children: [
              _gutter(
                logo == null
                    ? const Icon(PlotIcon.twist, size: composePillLogoSize)
                    : LogoImage(
                        url: logo,
                        size: composePillLogoSize,
                        fallback: const Icon(
                          PlotIcon.twist,
                          size: composePillLogoSize,
                        ),
                      ),
              ),
              const SizedBox(width: composePillIconGap),
              Expanded(
                child: Text(
                  target.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle,
                ),
              ),
            ],
          );
        }(),

      ChannelPillData(:final target) => () {
          final lt = target.linkType;
          final logo =
              lt == null ? null : (isDark ? (lt.logoDark ?? lt.logo) : lt.logo);
          // The channel is the primary distinguishing element, so it leads
          // (after the connection label, when there is one) and the connector
          // name trails muted: "{connection} › {channel}  {connector}".
          final ct = target.target;
          final connectionLabel = ct?.accountName;
          final connectorName = ct?.connectorName;
          final channelTitle = target.channel?.title ?? target.label;
          return Row(
            children: [
              _gutter(
                logo == null
                    ? const Icon(PlotIcon.link, size: composePillLogoSize)
                    : LogoImage(
                        url: logo,
                        size: composePillLogoSize,
                        fallback: const Icon(
                          PlotIcon.link,
                          size: composePillLogoSize,
                        ),
                      ),
              ),
              const SizedBox(width: composePillIconGap),
              Expanded(
                child: Row(
                  children: [
                    if (connectionLabel != null &&
                        connectionLabel.isNotEmpty) ...[
                      Flexible(
                        child: Text(
                          connectionLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: nameStyle,
                        ),
                      ),
                      Text(' › ', style: metaStyle),
                    ],
                    Flexible(
                      child: Text(
                        channelTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle,
                      ),
                    ),
                    if (connectorName != null && connectorName.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        connectorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: metaStyle,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        }(),

      FocusPillData(:final priority) => Row(
          children: [
            Expanded(
              child: FocusLabel(
                priority: priority,
                iconColumnWidth: composePillGutter,
                iconGap: composePillIconGap,
                iconSize: composePillLogoSize,
              ),
            ),
          ],
        ),

      ConnectionPillData(:final target, :final label, :final detail) => () {
          final isPlotNative = target.kind == ComposeTargetKind.note ||
              target.kind == ComposeTargetKind.chat;
          final lt = target.linkType;
          final logo = isPlotNative
              ? null
              : (lt == null
                  ? null
                  : (isDark ? (lt.logoDark ?? lt.logo) : lt.logo));
          final displayName = label ?? target.label;
          final Widget leading = isPlotNative
              ? SvgPicture.asset(
                  'assets/plot-icon.svg',
                  width: composePillLogoSize,
                  height: composePillLogoSize,
                )
              : (logo == null
                  ? const Icon(PlotIcon.link, size: composePillLogoSize)
                  : LogoImage(
                      url: logo,
                      size: composePillLogoSize,
                      fallback: const Icon(
                        PlotIcon.link,
                        size: composePillLogoSize,
                      ),
                    ));
          return Row(
            children: [
              _gutter(leading),
              const SizedBox(width: composePillIconGap),
              Expanded(
                child: _nameMetaLine(
                  name: displayName,
                  meta: detail,
                  nameStyle: nameStyle,
                  metaStyle: metaStyle,
                ),
              ),
            ],
          );
        }(),
    };
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  /// Centres a leading [glyph] within the shared [composePillGutter] so glyphs
  /// of differing intrinsic widths (avatars, logos, badges, icons) share one
  /// vertical centreline and every name starts at the same x.
  Widget _gutter(Widget glyph) =>
      SizedBox(width: composePillGutter, child: Center(child: glyph));

  /// A 24px circular count badge: a filled chip that sits just off the page
  /// surface, with the count in the full `foreground` for a strong read.
  Widget _countBadge(BuildContext context, int count) {
    final scheme = context.colour;
    final isDark = scheme.brightness == Brightness.dark;
    // Chip fill steps gently off the page surface — a touch lighter than the
    // dark page in dark mode, a touch darker than the near-white page in light
    // mode — keeping the surface's faint warm tint either way. Deriving from
    // `background` (rather than the old `muted @ 0.2α`) fixes both: the dark
    // chip no longer over-brightens against the page, and the light chip is
    // actually visible. The number uses `foreground` so it stays high-contrast
    // against the chip (the old muted-on-muted pairing was too soft).
    final badgeBackground = scheme.colours.background
        .withLightness(isDark ? 0.33 : 0.93)
        .toColor();
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: badgeBackground,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          '$count',
          style: context.theme.typography.xs.copyWith(
            color: scheme.foreground,
          ),
        ),
      ),
    );
  }

  /// A single-line name + optional inline meta (e.g. "Greg  greg@acme.com").
  ///
  /// Rendered as one [Text.rich] so the name and meta truncate as a single
  /// combination: the trailing meta (the email / address list) ellipsizes
  /// first and the name is only clipped once it alone overflows the row. This
  /// shows full names whenever the row is wide enough, trimming only the email.
  Widget _nameMetaLine({
    required String name,
    required String? meta,
    required TextStyle nameStyle,
    required TextStyle metaStyle,
  }) {
    if (meta == null || meta.isEmpty) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: nameStyle,
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: name, style: nameStyle),
          const WidgetSpan(child: SizedBox(width: 8)),
          TextSpan(text: meta, style: metaStyle),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Format a single [Actor] as "name — email" when both differ, or just the
  /// name/email fallback when the email is absent or identical to the name.
  static String _formatActorLine(Actor a) {
    final email = a.email;
    return (email != null && email.isNotEmpty && email != a.nameOrEmail)
        ? '${a.nameOrEmail} — $email'
        : a.nameOrEmail;
  }

  /// Wrap [child] in an [FTooltip] showing [lines] joined by newlines.
  /// Returns [child] unchanged when [lines] is empty.
  Widget _withTooltip(
    BuildContext context,
    List<String> lines,
    Widget child,
  ) {
    if (lines.isEmpty) return child;
    final text = lines.join('\n');
    return FTooltip(
      tipBuilder: (context, controller) => Text(text),
      child: child,
    );
  }
}
