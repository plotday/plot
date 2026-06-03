part of 'compose_targets.dart';

/// Immutable state for the materialized target list.
class ComposeTargetsState extends Equatable {
  const ComposeTargetsState({required this.targets});

  /// The cached, globally-MRU-ordered base list of compose targets. Built by
  /// [ComposeTargetsBloc.refresh]; updated in place by
  /// [ComposeTargetsBloc.prependToCache] on thread creation.
  final List<ComposeTarget> targets;

  ComposeTargetsState copyWith({List<ComposeTarget>? targets}) =>
      ComposeTargetsState(targets: targets ?? this.targets);

  @override
  List<Object?> get props => [targets];
}
