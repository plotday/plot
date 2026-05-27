import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/widget.dart';

/// A connector link type the current user can create from Plot. Sourced from
/// enabled channels whose link types declare a `createDefault: true` status.
class CreateTarget {
  CreateTarget({
    required this.twist,
    this.channel,
    required this.linkType,
    required this.defaultStatus,
  })  : connectorName =
            CreateLinkUserAction.parseTwistName(twist.name).connectorName,
        accountName =
            CreateLinkUserAction.parseTwistName(twist.name).accountName;

  final TwistInstance twist;
  /// Null for connection-scoped link types (`linkType.targets` is
  /// `"contacts"` or `"addresses"`), where the picker shows one chip per
  /// connection rather than per channel.
  final Channel? channel;
  final LinkTypeConfig linkType;
  final LinkStatus defaultStatus;
  final String connectorName;
  final String? accountName;

  /// True for link types that emit a single chip per connection
  /// (`"contacts"` for closed-roster DMs, `"addresses"` for open address
  /// spaces like Gmail) — i.e. anything that isn't channel-targeted.
  bool get isDmType =>
      linkType.targets == 'contacts' || linkType.targets == 'addresses';

  /// Stable identity for MRU keying and de-duping.
  String get key => isDmType
      ? '${twist.id}||${linkType.type}'
      : '${twist.id}|${channel!.channelId}|${linkType.type}';

  String get title =>
      'Create new $connectorName ${linkType.label.toLowerCase()}';

  /// For channel-type targets: "{channel}" or "{channel} ({account})".
  /// For DM-type targets: the connection display name, e.g. "Slack: Acme Workspace".
  String get subtitle {
    if (isDmType) {
      final label = accountName ?? twist.name;
      return '$connectorName: $label';
    }
    final ch = channel!;
    return accountName == null ? ch.title : '${ch.title} ($accountName)';
  }

  String get searchText {
    if (isDmType) {
      return '$connectorName ${linkType.label} ${accountName ?? ''}'.toLowerCase();
    }
    return '$connectorName ${linkType.label} ${channel!.title} ${accountName ?? ''}'
        .toLowerCase();
  }

  /// Short label for chip text.
  /// - Channel-type: "Gmail · thread"
  /// - DM-type: "Slack: Acme Workspace · DM" (connection display name)
  String get chipLabel {
    if (isDmType) {
      final label = accountName ?? connectorName;
      return '$connectorName: $label · ${linkType.label.toLowerCase()}';
    }
    return '$connectorName · ${linkType.label.toLowerCase()}';
  }

  CreateLinkUserAction toUserAction() => CreateLinkUserAction(
        twistInstanceId: twist.id.toString(),
        channelId: isDmType ? null : channel!.channelId,
        linkType: linkType.type,
        status: defaultStatus.status,
        connectorName: connectorName,
        linkTypeLabel: linkType.label,
        channelName: isDmType ? subtitle : channel!.title,
        accountName: accountName,
        logo: linkType.logo,
        logoDark: linkType.logoDark,
        dmTargets: linkType.targets,
      );
}

/// Build every create-target available to the current user across all enabled
/// channels.
///
/// A link type opts in by declaring a status with `createDefault: true`.
/// Channel-level linkTypes (dynamic, per-team) take precedence for the
/// status list, but if the channel-level config has no `createDefault`
/// status (typical for connections set up before a connector added the
/// marker), the twist-level linkTypes are consulted for a default. The
/// connector's `onCreateLink` must accept the resulting status id
/// (Linear, for example, resolves a category like "unstarted" to a
/// team-specific state UUID).
///
/// For link types with `targets: "contacts"` (DM-type), one [CreateTarget]
/// is emitted per twist instance (connection/workspace) instead of per
/// channel. This ensures the connection chip shows a single entry for the
/// account (e.g. "Slack: Acme Workspace") from which the user selects
/// individual recipients.
Future<List<CreateTarget>> loadCreateTargets() async {
  final channels = await Channel.getAllEnabled();
  final result = <CreateTarget>[];
  // Tracks which (twistId, linkTypeType) pairs have already been emitted as
  // DM-type targets so we emit exactly one per twist instance, not one per
  // enabled channel on that instance.
  final emittedDmKeys = <String>{};

  for (final channel in channels) {
    final twist = TwistInstance.fromCache(channel.twistInstanceId);
    if (twist == null) continue;
    final channelConfigs = channel.parsedLinkTypes;
    final twistConfigs = twist.parsedLinkTypes;
    if (channelConfigs == null && twistConfigs == null) continue;

    final primaryConfigs = channelConfigs ?? twistConfigs!;
    for (final linkType in primaryConfigs) {
      var defaultStatus = linkType.statuses
          ?.where((s) => s.createDefault)
          .firstOrNull;
      if (defaultStatus == null && channelConfigs != null) {
        defaultStatus = twistConfigs
            ?.where((c) => c.type == linkType.type)
            .firstOrNull
            ?.statuses
            ?.where((s) => s.createDefault)
            .firstOrNull;
      }
      if (defaultStatus == null) continue;

      if (linkType.targets == 'contacts' || linkType.targets == 'addresses') {
        // Connection-scoped: emit one target per twist instance (connection),
        // not per channel. The recipient picker filters / accepts inputs
        // per the linkType.targets mode.
        final dmKey = '${twist.id}|${linkType.type}';
        if (!emittedDmKeys.add(dmKey)) continue;
        result.add(CreateTarget(
          twist: twist,
          channel: null,
          linkType: linkType,
          defaultStatus: defaultStatus,
        ));
      } else {
        // Channel-type: existing per-channel enumeration.
        result.add(CreateTarget(
          twist: twist,
          channel: channel,
          linkType: linkType,
          defaultStatus: defaultStatus,
        ));
      }
    }
  }
  return result;
}

/// List-tile builder for the NewThreadPage connection picker. Displays
/// the connector logo, the normalized link-type label as the title
/// ("Gmail email"), and the connection / account as the subtitle.
ListTile connectionTargetTile(BuildContext context, CreateTarget target) {
  final isDark = context.read<ThemeBloc>().isDarkMode(context);
  final logo = isDark
      ? (target.linkType.logoDark ?? target.linkType.logo)
      : target.linkType.logo;
  final subtitle = connectionTargetSubtitle(target);
  return ListTile(
    leadingBuilder: logo != null
        ? (_, _) => Builder(
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  left: context.theme.spacing.lg,
                  right: 8,
                ),
                child: LogoImage(
                  url: logo,
                  size: 16,
                  fallback: const Icon(PlotIcon.link, size: 16),
                ),
              ),
            )
        : null,
    icon: logo == null ? PlotIcon.link : null,
    title: connectionTargetTitle(target),
    subtitle: subtitle.isEmpty ? null : subtitle,
  );
}

/// Shared list-tile builder for "Create new …" rows in pickers.
ListTile createTargetTile(BuildContext context, CreateTarget target) {
  final isDark = context.read<ThemeBloc>().isDarkMode(context);
  final logo = isDark
      ? (target.linkType.logoDark ?? target.linkType.logo)
      : target.linkType.logo;
  return ListTile(
    leadingBuilder: logo != null
        ? (_, _) => Builder(
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  left: context.theme.spacing.lg,
                  right: 8,
                ),
                child: LogoImage(
                  url: logo,
                  size: 16,
                  fallback: const Icon(PlotIcon.add, size: 16),
                ),
              ),
            )
        : null,
    icon: logo == null ? PlotIcon.add : null,
    title: target.title,
    subtitle: target.subtitle,
  );
}
