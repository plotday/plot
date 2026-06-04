import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart'
    show Channel, CreateLinkUserAction, LinkTypeConfig, TwistInstance, Uuid;
import 'package:plot/widget/compose/connection_choice.dart';
import 'package:plot/widget/connection_targets.dart';

/// What kind of thread a [ComposeTarget] creates.
///
/// `note`/`chat` are the Plot-native variants (the "Plot" prefix and the
/// dedicated Task type are dropped — see the two-step-thread-creation spec);
/// `connector` is a connection/channel/DM/address target backed by a
/// [CreateTarget]; `twist` is a chat-with-a-twist target (Plot AI, etc.).
enum ComposeTargetKind { note, chat, connector, twist }

/// A single row in the step-1 target picker: a "way to create a thread".
///
/// Generalizes today's [ConnectionChoice] with a **team scope** and an
/// optional **roster** (the contacts/groups carried into step-2 compose), so
/// repeatable combinations like "Chat (Acme) with Greg" and "Gmail with Greg"
/// rank as distinct entries in the global MRU.
///
/// The [signature] is the stable MRU key (see [composeConnectorSignature] and
/// friends); the [label] is the display string with parentheticals resolved
/// against the caller-supplied context (see the named constructors). Both are
/// computed once at construction so the value is cheap to compare and render.
///
/// A target maps back to what step-2 needs via [toConnectionChoice] /
/// [toUserAction] — reusing the existing [CreateTarget] / [ConnectionChoice]
/// plumbing rather than duplicating it.
class ComposeTarget extends Equatable {
  const ComposeTarget._({
    required this.kind,
    required this.signature,
    required this.label,
    this.connection,
    this.target,
    this.linkType,
    this.channel,
    this.teamId,
    this.contacts = const [],
    this.groups = const [],
    this.inviteEmails = const [],
    this.priorityId,
  });

  /// A Plot **Note** target (no roster). [teamId] null = Personal.
  ///
  /// [hasTeams] should be true when the user belongs to ≥1 team; only then is
  /// the team / Personal parenthetical shown. [teamName] is the display name
  /// for [teamId] (ignored when [teamId] is null → "Personal").
  factory ComposeTarget.note({
    BigInt? teamId,
    required bool hasTeams,
    String? teamName,
  }) {
    return ComposeTarget._(
      kind: ComposeTargetKind.note,
      signature: composeNoteSignature(teamId),
      label: _plotLabel('Note', teamId, hasTeams: hasTeams, teamName: teamName),
      teamId: teamId,
    );
  }

  /// A Plot **Chat** target. [teamId] null = Personal. The optional roster
  /// ([contacts]/[groups]) is carried into step-2 compose and folded into the
  /// signature so "Chat (Acme) with Greg" ranks distinctly.
  ///
  /// [contactDetail] (e.g. "Greg Smith", or "foo@bar.com" for an unresolved
  /// invite) is appended to the label so a rostered chat combo renders
  /// distinctly from the bare "Chat" template — otherwise the two are visually
  /// identical and one is just noise. Pass null (the default) for a bare chat
  /// or when the roster can't be resolved to a name.
  ///
  /// [inviteEmails] carries pending email invitations (addresses the user typed
  /// that don't yet resolve to a known contact). They are folded into the
  /// signature so "Chat with foo@bar.com" ranks/dedups distinctly, and carried
  /// into step-2 compose as the draft's pending invites.
  factory ComposeTarget.chat({
    BigInt? teamId,
    required bool hasTeams,
    String? teamName,
    String? contactDetail,
    List<Uuid> contacts = const [],
    List<Uuid> groups = const [],
    List<String> inviteEmails = const [],
  }) {
    return ComposeTarget._(
      kind: ComposeTargetKind.chat,
      signature: composeChatSignature(
        teamId,
        contacts: contacts,
        groups: groups,
        inviteEmails: inviteEmails,
      ),
      label: _appendDetail(
        _plotLabel('Chat', teamId, hasTeams: hasTeams, teamName: teamName),
        contactDetail,
      ),
      teamId: teamId,
      contacts: contacts,
      groups: groups,
      inviteEmails: inviteEmails,
    );
  }

  /// A Plot focus-note target: a private note pre-filed into [priorityId].
  /// Uses the [ComposeTargetKind.note] kind; the signature is widened with the
  /// focus id so distinct focuses rank as distinct rows. [teamId] is the
  /// focus's most-common Plot scope (null = Personal). [title] is the focus's
  /// display name — it becomes the [label], which makes the row searchable by
  /// focus name and keeps the per-focus rows visually distinct (the display
  /// dedup collapses rows that share a label).
  factory ComposeTarget.focusNote({
    required Uuid priorityId,
    required BigInt? teamId,
    String title = 'Note',
  }) {
    return ComposeTarget._(
      kind: ComposeTargetKind.note,
      signature: 'note:${teamId?.toString() ?? 'personal'}:p=$priorityId',
      label: title,
      teamId: teamId,
      priorityId: priorityId,
    );
  }

  /// A chat-with-a-twist target (e.g. Plot AI).
  factory ComposeTarget.twist(
    TwistInstance twist, {
    required List<TwistInstance> allInstances,
    String? teamName,
  }) {
    final choice = TwistConnectionChoice(
      twist,
      allInstances: allInstances,
      teamName: teamName,
    );
    return ComposeTarget._(
      kind: ComposeTargetKind.twist,
      signature: composeTwistSignature(twist.id),
      label: choice.label,
      connection: twist,
      teamId: twist.teamId,
    );
  }

  /// A connector target backed by a [CreateTarget] (Slack channel, Gmail
  /// connection, Linear team, …), optionally widened with a [contacts] /
  /// [groups] roster carried into compose.
  ///
  /// [connectionCount] is how many connections the user has **for this
  /// connector** (same connector package). The account-label parenthetical is
  /// shown only when it is > 1. [channelDetail] / [contactDetail] append after
  /// the connector label (` · #general`, ` · Greg Smith`).
  factory ComposeTarget.connector(
    CreateTarget target, {
    required int connectionCount,
    String? channelDetail,
    String? contactDetail,
    List<Uuid> contacts = const [],
    List<Uuid> groups = const [],
  }) {
    return ComposeTarget._(
      kind: ComposeTargetKind.connector,
      signature: composeConnectorSignature(
        twistInstanceId: target.twist.id.toString(),
        channelId: target.channel?.channelId,
        linkType: target.linkType.type,
        dmTargets: target.compose.targets,
        contacts: contacts,
        groups: groups,
      ),
      label: _connectorLabel(
        target,
        connectionCount: connectionCount,
        channelDetail: channelDetail,
        contactDetail: contactDetail,
      ),
      connection: target.twist,
      target: target,
      linkType: target.linkType,
      channel: target.channel,
      // Connector targets inherit the team from the connection.
      teamId: target.twist.teamId,
      contacts: contacts,
      groups: groups,
    );
  }

  final ComposeTargetKind kind;

  /// Stable MRU/dedup key. See [composeConnectorSignature] etc.
  final String signature;

  /// Display string with parentheticals resolved (see named constructors).
  final String label;

  /// The connector connection (or the twist for [ComposeTargetKind.twist]);
  /// null for note/chat.
  final TwistInstance? connection;

  /// The underlying [CreateTarget] for [ComposeTargetKind.connector]; null
  /// otherwise. Retained so [toUserAction] / [toConnectionChoice] reuse the
  /// existing plumbing without rebuilding it.
  final CreateTarget? target;

  /// Connector link type (channel connectors carry [channel] too); null for
  /// note/chat/twist.
  final LinkTypeConfig? linkType;
  final Channel? channel;

  /// Team scope: null = Personal. For note/chat this is the chosen team; for
  /// connector/twist targets it is inherited from the connection.
  final BigInt? teamId;

  /// Pre-filled roster carried into step-2 compose; empty for bare templates.
  final List<Uuid> contacts;
  final List<Uuid> groups;

  /// Pending email invitations carried into step-2 compose: addresses the user
  /// typed in the picker that don't (yet) resolve to a known contact. Only a
  /// [ComposeTargetKind.chat] target carries these (a Plot Chat that invites by
  /// email); empty for every other kind.
  final List<String> inviteEmails;

  /// For a focus-note target, the focus this note is filed into; null for all
  /// other kinds. Carried into step-2 compose so the focus is pre-selected.
  final Uuid? priorityId;

  /// Bridge to the existing compose-surface selection model. Returns a
  /// [ConnectionChoice] that step-2 applies via its established apply path.
  /// Note: the roster ([contacts]/[groups]) is carried on the [ComposeTarget]
  /// itself; the returned choice only selects the connection/variant.
  ConnectionChoice toConnectionChoice() => switch (kind) {
        ComposeTargetKind.note => ConnectionChoice.plotNote,
        ComposeTargetKind.chat => ConnectionChoice.plotChat,
        ComposeTargetKind.connector => ConnectionChoice.target(target!),
        // The roster of allInstances is only needed for the twist label, which
        // is already baked into [label]; an empty list is fine for selection.
        ComposeTargetKind.twist =>
          ConnectionChoice.twist(connection!, allInstances: const []),
      };

  /// The [CreateLinkUserAction] to attach to the draft for connector targets,
  /// or null for Plot note/chat and twist targets (which select via other
  /// state). Delegates to [CreateTarget.toUserAction].
  CreateLinkUserAction? toUserAction() => target?.toUserAction();

  /// Plot Note/Chat label: bare `Note`/`Chat`, plus ` (Team)` / ` (Personal)`
  /// only when the user belongs to ≥1 team.
  static String _plotLabel(
    String base,
    BigInt? teamId, {
    required bool hasTeams,
    String? teamName,
  }) {
    if (!hasTeams) return base;
    final scope = teamId == null ? 'Personal' : (teamName ?? 'Team');
    return '$base ($scope)';
  }

  /// Connector label: `{Connector}`, plus ` ({account label})` only when the
  /// connector has >1 connection, plus any channel/contact detail.
  static String _connectorLabel(
    CreateTarget target, {
    required int connectionCount,
    String? channelDetail,
    String? contactDetail,
  }) {
    final buf = StringBuffer(target.connectorName);
    final account = target.accountName;
    if (connectionCount > 1 && account != null && account.isNotEmpty) {
      buf.write(' ($account)');
    }
    return _appendDetail(buf.toString(), channelDetail ?? contactDetail);
  }

  /// Appends ` · {detail}` to [label] when [detail] is non-empty; otherwise
  /// returns [label] unchanged. Used to surface a channel/contact roster on a
  /// target's label so rostered combos render distinctly from bare templates.
  static String _appendDetail(String label, String? detail) =>
      (detail != null && detail.isNotEmpty) ? '$label · $detail' : label;

  @override
  List<Object?> get props => [
        kind,
        signature,
        label,
        connection?.id,
        linkType?.type,
        channel?.id,
        teamId,
        contacts,
        groups,
        inviteEmails,
        priorityId,
      ];
}
