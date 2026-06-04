import 'package:plot/store/store.dart' show CreateLinkUserAction, TwistInstance;
import 'package:plot/widget/connection_targets.dart' show CreateTarget;

/// A selectable connection on the compose surface. Either a real
/// [CreateTarget] (Slack channel, Linear team, …), the single Plot thread
/// choice, or a [TwistInstance] (chat with a twist — Plot AI, etc.).
sealed class ConnectionChoice {
  String get key;
  String get label;
  String? get logo;
  String? get logoDark;
  String get searchText;

  /// Returns the [CreateLinkUserAction] to attach to the draft, or null
  /// for the Plot-thread / twist choices (which use other state to track
  /// selection — twist selection lives in `thread.icon` via
  /// `_selectTwist`).
  CreateLinkUserAction? toUserAction();

  /// The single Plot thread choice (no note/chat distinction). The underlying
  /// data model is a regular Plot thread; the compose page derives
  /// shared-vs-private behaviour (placeholder, send/save) from whether
  /// recipients are present, not from a stored mode. This scope-less default
  /// is for callers that only need "a Plot thread"; the compose page builds a
  /// scoped [PlotThreadChoice] (carrying the team) so the connection field can
  /// show "Plot" with the team — see `_plotChoiceForDraft`.
  static const PlotThreadChoice plotDefault = PlotThreadChoice();

  /// Wrap a real [CreateTarget] as a choice.
  factory ConnectionChoice.target(CreateTarget target) =
      TargetConnectionChoice;

  /// Wrap a [TwistInstance] as a choice. Only twists whose `threadType`
  /// is non-null should be wrapped — the picker filters before calling
  /// this constructor.
  factory ConnectionChoice.twist(
    TwistInstance twist, {
    required List<TwistInstance> allInstances,
    String? teamName,
  }) = TwistConnectionChoice;
}

/// The single Plot thread choice. Selecting it clears any
/// [CreateLinkUserAction] on the draft and any selected twist. Carries the
/// optional team scope ([teamId]/[teamName]) so the connection field can show
/// "Plot" with the team when the user belongs to ≥1 team ([hasTeams]).
class PlotThreadChoice implements ConnectionChoice {
  const PlotThreadChoice({this.teamId, this.teamName, this.hasTeams = false});

  /// Team scope: null = Personal.
  final BigInt? teamId;

  /// Display name for [teamId]; ignored when [teamId] is null.
  final String? teamName;

  /// Whether the user belongs to ≥1 team. The scope ([scopeLabel]) is surfaced
  /// only when true — a user with no teams just sees "Plot".
  final bool hasTeams;

  /// Scope shown beside "Plot" on the connection field: "Personal" or the team
  /// name when the user has teams; empty otherwise.
  String get scopeLabel {
    if (!hasTeams) return '';
    return teamId == null ? 'Personal' : (teamName ?? 'Team');
  }

  @override
  String get key => 'plot';

  @override
  String get label => 'Plot';

  @override
  String? get logo => null;

  @override
  String? get logoDark => null;

  @override
  String get searchText => 'plot note chat';

  @override
  CreateLinkUserAction? toUserAction() => null;
}

/// A real [CreateTarget] wrapped as a [ConnectionChoice].
class TargetConnectionChoice implements ConnectionChoice {
  TargetConnectionChoice(this.target);

  final CreateTarget target;

  @override
  String get key => target.key;

  @override
  String get label => target.chipLabel;

  @override
  String? get logo => target.linkType.logo;

  @override
  String? get logoDark => target.linkType.logoDark;

  @override
  String get searchText => target.searchText;

  @override
  CreateLinkUserAction? toUserAction() => target.toUserAction();
}

/// A [TwistInstance] wrapped as a [ConnectionChoice]. Used for "chat with"
/// targets like Plot AI. Selection is applied via the parent page's
/// existing `_selectTwist` path (sets `thread.icon = 'twist:N'`); this
/// choice does not produce a `CreateLinkUserAction`.
class TwistConnectionChoice implements ConnectionChoice {
  TwistConnectionChoice(
    this.twist, {
    required this.allInstances,
    this.teamName,
  });

  final TwistInstance twist;
  final List<TwistInstance> allInstances;
  final String? teamName;

  String get _displayThreadType =>
      twist.threadType ?? '${twist.handle.isEmpty ? twist.name : twist.handle} chat';

  String get _scopeSuffix {
    if (twist.multipleInstances) return '';
    final hasSibling = allInstances.any(
      (other) =>
          other.id != twist.id &&
          other.twistId == twist.twistId &&
          other.archivedAt == null,
    );
    if (!hasSibling) return '';
    final scopeLabel = twist.teamId == null ? 'Personal' : (teamName ?? 'Team');
    return ' ($scopeLabel)';
  }

  /// The thread-type label without the scope suffix (e.g. "Plot AI chat").
  /// Used as the second-line content of a step-1 twist row.
  String get threadTypeLabel => _displayThreadType;

  /// The disambiguating scope suffix (e.g. " (Personal)") shown only when the
  /// twist has sibling instances across scopes. Appended to the twist name in
  /// the step-1 twist row header.
  String get scopeSuffix => _scopeSuffix;

  @override
  String get key => 'twist:${twist.id}';

  @override
  String get label => '$_displayThreadType$_scopeSuffix';

  @override
  String? get logo => twist.logoUrl;

  @override
  String? get logoDark => twist.logoUrlDark;

  @override
  String get searchText =>
      '${_displayThreadType.toLowerCase()} ${(twist.handle.isEmpty ? twist.name : twist.handle).toLowerCase()}';

  @override
  CreateLinkUserAction? toUserAction() => null;
}
