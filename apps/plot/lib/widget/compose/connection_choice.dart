import 'package:plot/store/store.dart' show CreateLinkUserAction, TwistInstance;
import 'package:plot/widget/connection_targets.dart' show CreateTarget;

/// A selectable connection on the compose surface. Either a real
/// [CreateTarget] (Slack channel, Linear team, …), the synthetic
/// "Plot thread" choice that just clears any existing connection, or a
/// [TwistInstance] (chat with a twist — Plot AI, etc.).
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

  static const PlotThreadChoice plotThread = PlotThreadChoice._();

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

/// The synthetic "Plot thread" sentinel. Selecting it clears any
/// [CreateLinkUserAction] on the draft and clears any selected twist.
class PlotThreadChoice implements ConnectionChoice {
  const PlotThreadChoice._();

  @override
  String get key => 'plot:thread';

  @override
  String get label => 'Plot thread';

  @override
  String? get logo => null;

  @override
  String? get logoDark => null;

  @override
  String get searchText => 'plot thread';

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
