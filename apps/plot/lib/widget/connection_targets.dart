import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/theme.dart' show ThemeBloc;
import 'package:plot/store/store.dart';
import 'package:plot/style/spacing.dart';
import 'package:plot/widget/widget.dart';

/// A connector link type the current user can create from Plot. Sourced from
/// enabled channels whose link types declare a `compose` block.
class CreateTarget {
  CreateTarget({
    required this.twist,
    this.channel,
    required this.linkType,
    required this.compose,
    required this.defaultStatus,
  })  : connectorName =
            CreateLinkUserAction.parseTwistName(twist.name).connectorName,
        accountName = twist.accountLabel ??
            CreateLinkUserAction.parseTwistName(twist.name).accountName;

  final TwistInstance twist;
  /// Null for connection-scoped link types (`compose.targets` is
  /// `"contacts"` or `"addresses"`), where the picker shows one chip per
  /// connection rather than per channel.
  final Channel? channel;
  final LinkTypeConfig linkType;
  final ComposeConfig compose;
  final LinkStatus defaultStatus;
  final String connectorName;
  final String? accountName;

  /// True for link types that emit a single chip per connection
  /// (`"contacts"` for closed-roster DMs, `"addresses"` for open address
  /// spaces like Gmail) — i.e. anything that isn't channel-targeted.
  bool get isDmType =>
      compose.targets == 'contacts' || compose.targets == 'addresses';

  /// Display label for picker copy. Falls back to the linkType's label.
  String get _displayLabel => compose.label ?? linkType.label;

  /// Stable identity for MRU keying and de-duping. Delegates to
  /// [connectionTargetKey] so it stays byte-identical to the key recorded
  /// from a draft's [CreateLinkUserAction] (see [createLinkActionKey]).
  String get key => connectionTargetKey(
        twistInstanceId: twist.id.toString(),
        channelId: channel?.channelId,
        linkType: linkType.type,
        dmTargets: compose.targets,
      );

  String get title =>
      'Create new $connectorName ${_displayLabel.toLowerCase()}';

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
      return '$connectorName $_displayLabel ${accountName ?? ''}'.toLowerCase();
    }
    return '$connectorName $_displayLabel ${channel!.title} ${accountName ?? ''}'
        .toLowerCase();
  }

  /// Short label for chip text.
  /// - Channel-type: "Gmail · thread"
  /// - DM-type: "Slack: Acme Workspace · direct messages"
  String get chipLabel {
    if (isDmType) {
      final label = accountName ?? connectorName;
      return '$connectorName: $label · ${_displayLabel.toLowerCase()}';
    }
    return '$connectorName · ${_displayLabel.toLowerCase()}';
  }

  CreateLinkUserAction toUserAction() => CreateLinkUserAction(
        twistInstanceId: twist.id.toString(),
        channelId: isDmType ? null : channel!.channelId,
        linkType: linkType.type,
        status: defaultStatus.status,
        connectorName: connectorName,
        linkTypeLabel: _displayLabel,
        channelName: isDmType ? subtitle : channel!.title,
        accountName: accountName,
        logo: linkType.logo,
        logoDark: linkType.logoDark,
        dmTargets: compose.targets,
      );
}

/// Canonical identity/MRU key for a connection target. Shared by
/// [CreateTarget.key] and [createLinkActionKey] so a key recorded from a
/// draft's [CreateLinkUserAction] always matches the [CreateTarget] the
/// picker built — including DM-type targets (`contacts`/`addresses`), whose
/// key uses the `twist||linkType|targets` form rather than `twist|null|...`.
/// `contacts` and `addresses` are the only DM discriminants; any other value
/// (including the default `channels`) is treated as channel-type.
String connectionTargetKey({
  required String twistInstanceId,
  required String? channelId,
  required String linkType,
  required String? dmTargets,
}) {
  final isDm = dmTargets == 'contacts' || dmTargets == 'addresses';
  return isDm
      ? '$twistInstanceId||$linkType|$dmTargets'
      : '$twistInstanceId|$channelId|$linkType';
}

/// The [connectionTargetKey] for the connection a [CreateLinkUserAction]
/// targets. Used to record connection usage from a submitted draft so the
/// MRU keys line up with the [CreateTarget]s loaded for the picker.
String createLinkActionKey(CreateLinkUserAction action) => connectionTargetKey(
      twistInstanceId: action.twistInstanceId,
      channelId: action.channelId,
      linkType: action.linkType,
      dmTargets: action.dmTargets,
    );

/// Renders the optional roster suffix appended to a compose-target signature.
///
/// The two-step compose flow lets the same connection/channel be reused with
/// different rosters ("Chat (Acme) with Greg" vs "Chat (Acme) with Dana"), so
/// the signature widens the canonical connection key with the contacts and
/// groups carried into compose. Contact and group ids are sorted so the suffix
/// is stable regardless of selection order, and an **empty** roster yields an
/// empty suffix — that keeps a no-roster connector signature byte-identical to
/// [connectionTargetKey] / [CreateTarget.key] so historical `connectionMru`
/// entries (recorded before rosters existed) still match.
String rosterSignatureSuffix({
  Iterable<Uuid> contacts = const [],
  Iterable<Uuid> groups = const [],
}) {
  final c = contacts.map((u) => u.toString()).toList()..sort();
  final g = groups.map((u) => u.toString()).toList()..sort();
  final buf = StringBuffer();
  if (c.isNotEmpty) buf.write(':c=${c.join(',')}');
  if (g.isNotEmpty) buf.write(':g=${g.join(',')}');
  return buf.toString();
}

/// Renders the optional invite-email suffix appended to a chat signature.
///
/// A Plot chat can carry pending email invitations (addresses the user typed
/// in the step-1 picker that don't yet resolve to a known contact). These
/// widen the chat signature so "Chat with foo@bar.com" ranks and dedups
/// distinctly from the bare "Chat" template. Emails are lowercased and sorted
/// so the suffix is stable regardless of input order/case, and an **empty**
/// list yields an empty suffix (preserving the bare chat signature).
String inviteEmailSignatureSuffix(Iterable<String> emails) {
  final e = emails.map((s) => s.toLowerCase()).toList()..sort();
  return e.isEmpty ? '' : ':e=${e.join(',')}';
}

/// Canonical signature for the "Plot note" target. `teamId` null = Personal.
String composeNoteSignature(BigInt? teamId) =>
    'note:${teamId?.toString() ?? 'personal'}';

/// Canonical signature for a "Plot chat" target, widened with its roster and
/// any pending invite emails. `teamId` null = Personal. With an empty roster
/// and no invite emails this is just `chat:<team|personal>`.
String composeChatSignature(
  BigInt? teamId, {
  Iterable<Uuid> contacts = const [],
  Iterable<Uuid> groups = const [],
  Iterable<String> inviteEmails = const [],
}) =>
    'chat:${teamId?.toString() ?? 'personal'}'
    '${rosterSignatureSuffix(contacts: contacts, groups: groups)}'
    '${inviteEmailSignatureSuffix(inviteEmails)}';

/// Canonical signature for a "chat with a twist" target.
String composeTwistSignature(TwistInstanceId instanceId) =>
    'twist:$instanceId';

/// Canonical signature for a connector target ([CreateTarget]-shaped),
/// optionally widened with the roster carried into compose. The no-roster
/// form delegates to [connectionTargetKey] so it equals [CreateTarget.key].
String composeConnectorSignature({
  required String twistInstanceId,
  required String? channelId,
  required String linkType,
  required String? dmTargets,
  Iterable<Uuid> contacts = const [],
  Iterable<Uuid> groups = const [],
}) =>
    connectionTargetKey(
      twistInstanceId: twistInstanceId,
      channelId: channelId,
      linkType: linkType,
      dmTargets: dmTargets,
    ) +
    rosterSignatureSuffix(contacts: contacts, groups: groups);

/// Build every create-target available to the current user across all enabled
/// channels.
///
/// A link type opts in by declaring a `compose` block. Channel-level
/// linkTypes (dynamic, per-team) take precedence; the channel-level
/// `compose.status` may be a per-team status id (Linear's per-team
/// workflow state UUID) that overrides the connector-level symbolic
/// category — `onCreateLink` is responsible for resolving either.
///
/// For compose entries with `targets: "contacts"` or `"addresses"`, one
/// [CreateTarget] is emitted per twist instance (connection/workspace)
/// instead of per channel. This ensures the connection chip shows a single
/// entry for the account (e.g. "Slack: Acme Workspace") from which the user
/// selects individual recipients.
Future<List<CreateTarget>> loadCreateTargets() async {
  final channels = await Channel.getAllEnabled();
  final result = <CreateTarget>[];
  // Tracks which connection-scoped targets have already been emitted so we
  // emit exactly one per twist instance, not one per enabled channel on that
  // instance. Uses [connectionTargetKey] so the dedup key equals the
  // target's own key.
  final emittedDmKeys = <String>{};

  for (final channel in channels) {
    final twist = TwistInstance.fromCache(channel.twistInstanceId);
    if (twist == null) continue;
    final channelConfigs = channel.parsedLinkTypes;
    final twistConfigs = twist.parsedLinkTypes;
    if (channelConfigs == null && twistConfigs == null) continue;

    final primaryConfigs = channelConfigs ?? twistConfigs!;
    for (final linkType in primaryConfigs) {
      final compose = linkType.compose;
      if (compose == null) continue;

      // Resolve compose.status to a LinkStatus. Try the channel-level
      // statuses first, then fall back to the twist-level config (covers
      // symbolic categories like "unstarted" that resolve per-team in
      // onCreateLink).
      final localStatuses = linkType.statuses ?? const <LinkStatus>[];
      var defaultStatus = localStatuses
          .where((s) => s.status == compose.status)
          .firstOrNull;
      defaultStatus ??= twistConfigs
          ?.where((c) => c.type == linkType.type)
          .firstOrNull
          ?.statuses
          ?.where((s) => s.status == compose.status)
          .firstOrNull;
      // Synthesize a passthrough status if neither level declares one — the
      // connector still receives `draft.status = compose.status` and
      // resolves it. Symbolic compose statuses (Linear's "unstarted",
      // Airtable's STATUS_TODO before any base option is added) rely on this.
      defaultStatus ??= LinkStatus(
        status: compose.status,
        label: compose.status,
      );

      if (compose.targets == 'contacts' || compose.targets == 'addresses') {
        // Connection-scoped: emit one target per twist instance (connection)
        // per compose targets mode, not per channel. A linkType with two
        // compose entries (one channels, one contacts) — possible once
        // multi-compose is supported — would dedupe each separately.
        final dmKey = connectionTargetKey(
          twistInstanceId: twist.id.toString(),
          channelId: null,
          linkType: linkType.type,
          dmTargets: compose.targets,
        );
        if (!emittedDmKeys.add(dmKey)) continue;
        result.add(CreateTarget(
          twist: twist,
          channel: null,
          linkType: linkType,
          compose: compose,
          defaultStatus: defaultStatus,
        ));
      } else {
        // Channel-type: per-channel enumeration.
        result.add(CreateTarget(
          twist: twist,
          channel: channel,
          linkType: linkType,
          compose: compose,
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
