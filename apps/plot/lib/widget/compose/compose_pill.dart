import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart' show Actor, GroupRow, Priority;
import 'package:plot/style/colors.dart';
import 'package:plot/widget/avatar.dart';
import 'package:plot/widget/compose/compose_target.dart';
import 'package:plot/widget/icon.dart';
import 'package:plot/widget/logo_image.dart';
import 'package:plot/widget/priority.dart';

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

/// A non-connection twist (assistant): logo + name. Muted (reads as secondary
/// to people in the same section).
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

/// A fully-rounded pill representing a single compose target (person, group,
/// connection, focus, twist, or channel).
///
/// Focus / hover state is supplied by the parent (a [PillGrid]). When
/// [focused], the pill shows an accent border and soft fill; at rest it is
/// transparent with a hairline border.
///
/// Group and ad-hoc pills are wrapped in an [FTooltip] listing all member
/// names and addresses.
class ComposePill extends StatelessWidget {
  const ComposePill({
    required this.data,
    required this.focused,
    required this.onTap,
    this.onRemove,
    super.key,
  });

  final ComposePillData data;
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final isDark = context.read<ThemeBloc>().isDarkMode(context);
    final colors = context.theme.colors;

    // Border and fill: stronger/accent + soft fill when focused; hairline at rest.
    final border = focused
        ? Border.all(color: colors.primary, width: 1.5)
        : Border.all(color: colors.border, width: 1);
    final bgColor = focused ? context.colour.editableBackground : null;

    final pill = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(7, 6, 13, 6),
        decoration: BoxDecoration(
          color: bgColor,
          border: border,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildContent(context, isDark),
            if (onRemove != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onRemove,
                child: Icon(
                  PlotIcon.close,
                  size: 12,
                  color: colors.mutedForeground,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return switch (data) {
      GroupPillData(:final members) => _withTooltip(
          context,
          members.map(_formatActorLine).toList(),
          pill,
        ),
      AdHocGroupPillData(:final actors, :final inviteEmails) => _withTooltip(
          context,
          [...actors.map(_formatActorLine), ...inviteEmails],
          pill,
        ),
      _ => pill,
    };
  }

  /// The inner content for each variant: leading slot + text.
  Widget _buildContent(BuildContext context, bool isDark) {
    final colors = context.theme.colors;
    final nameStyle = context.theme.typography.md;
    final metaStyle = nameStyle.copyWith(color: colors.mutedForeground);

    return switch (data) {
      ContactPillData(:final actor) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Avatar(actor: actor, size: 24, tooltip: false),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: _nameMetaColumn(
                context,
                name: actor.nameOrEmail,
                meta: actor.email,
                nameStyle: nameStyle,
                metaStyle: metaStyle,
              ),
            ),
          ],
        ),

      GroupPillData(:final group, :final members) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _countBadge(context, members.length),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: _nameMetaColumn(
                context,
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
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _countBadge(context, total),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  names,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle,
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
            mainAxisSize: MainAxisSize.min,
            children: [
              logo == null
                  ? const Icon(PlotIcon.twist, size: 22)
                  : LogoImage(
                      url: logo,
                      size: 22,
                      fallback: const Icon(PlotIcon.twist, size: 22),
                    ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  target.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle.copyWith(color: colors.mutedForeground),
                ),
              ),
            ],
          );
        }(),

      ChannelPillData(:final target) => () {
          final lt = target.linkType;
          final logo =
              lt == null ? null : (isDark ? (lt.logoDark ?? lt.logo) : lt.logo);
          final channelTitle = target.channel?.title;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              logo == null
                  ? const Icon(PlotIcon.link, size: 22)
                  : LogoImage(
                      url: logo,
                      size: 22,
                      fallback: const Icon(PlotIcon.link, size: 22),
                    ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: _nameMetaColumn(
                  context,
                  name: target.label,
                  meta: channelTitle,
                  nameStyle: nameStyle,
                  metaStyle: metaStyle,
                ),
              ),
            ],
          );
        }(),

      FocusPillData(:final priority) => Flexible(
          child: FocusLabel(priority: priority),
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
              ? SvgPicture.asset('assets/plot-icon.svg', width: 22, height: 22)
              : (logo == null
                  ? const Icon(PlotIcon.link, size: 22)
                  : LogoImage(
                      url: logo,
                      size: 22,
                      fallback: const Icon(PlotIcon.link, size: 22),
                    ));
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading,
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: _nameMetaColumn(
                  context,
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

  /// A 24px circular count badge (muted background, muted foreground text).
  Widget _countBadge(BuildContext context, int count) {
    final colors = context.theme.colors;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: colors.muted.withValues(alpha: 0.2),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          '$count',
          style: context.theme.typography.xs.copyWith(
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
  }

  /// A two-row name + optional meta column (meta ellipsizes).
  Widget _nameMetaColumn(
    BuildContext context, {
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: nameStyle,
        ),
        Text(
          meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metaStyle,
        ),
      ],
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
