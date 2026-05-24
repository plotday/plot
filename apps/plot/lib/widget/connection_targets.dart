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
    required this.channel,
    required this.linkType,
    required this.defaultStatus,
  })  : connectorName =
            CreateLinkUserAction.parseTwistName(twist.name).connectorName,
        accountName =
            CreateLinkUserAction.parseTwistName(twist.name).accountName;

  final TwistInstance twist;
  final Channel channel;
  final LinkTypeConfig linkType;
  final LinkStatus defaultStatus;
  final String connectorName;
  final String? accountName;

  /// Stable identity for MRU keying and de-duping.
  String get key => '${twist.id}|${channel.channelId}|${linkType.type}';

  String get title =>
      'Create new $connectorName ${linkType.label.toLowerCase()}';

  String get subtitle =>
      accountName == null ? channel.title : '${channel.title} ($accountName)';

  String get searchText =>
      '$connectorName ${linkType.label} ${channel.title} ${accountName ?? ''}'
          .toLowerCase();

  /// Short label for chip text: "Gmail · thread".
  String get chipLabel =>
      '$connectorName · ${linkType.label.toLowerCase()}';

  CreateLinkUserAction toUserAction() => CreateLinkUserAction(
        twistInstanceId: twist.id.toString(),
        channelId: channel.channelId,
        linkType: linkType.type,
        status: defaultStatus.status,
        connectorName: connectorName,
        linkTypeLabel: linkType.label,
        channelName: channel.title,
        accountName: accountName,
        logo: linkType.logo,
        logoDark: linkType.logoDark,
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
Future<List<CreateTarget>> loadCreateTargets() async {
  final channels = await Channel.getAllEnabled();
  final result = <CreateTarget>[];
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
      result.add(CreateTarget(
        twist: twist,
        channel: channel,
        linkType: linkType,
        defaultStatus: defaultStatus,
      ));
    }
  }
  return result;
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
