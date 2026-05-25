import 'package:plot/store/store.dart' show CreateLinkUserAction;
import 'package:plot/widget/connection_targets.dart' show CreateTarget;

/// A selectable connection on the compose surface. Either a real
/// [CreateTarget] (Slack channel, Linear team, …) or the synthetic
/// "Plot thread" choice that just clears any existing connection.
sealed class ConnectionChoice {
  String get key;
  String get label;
  String? get logo;
  String? get logoDark;
  String get searchText;

  /// Returns the [CreateLinkUserAction] to attach to the draft, or null
  /// for the Plot-thread choice (which removes any existing action).
  CreateLinkUserAction? toUserAction();

  static const PlotThreadChoice plotThread = PlotThreadChoice._();

  /// Wrap a real [CreateTarget] as a choice.
  factory ConnectionChoice.target(CreateTarget target) =
      TargetConnectionChoice;
}

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
