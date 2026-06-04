part of 'compose_targets.dart';

/// Immutable state for the materialized target list.
class ComposeTargetsState extends Equatable {
  const ComposeTargetsState({required this.targets});

  /// The cached, globally-MRU-ordered base list of compose target VIEWS. Built
  /// by [ComposeTargetsBloc.refresh]; updated in place by
  /// [ComposeTargetsBloc.prependToCache] on thread creation.
  final List<ComposeTargetView> targets;

  ComposeTargetsState copyWith({List<ComposeTargetView>? targets}) =>
      ComposeTargetsState(targets: targets ?? this.targets);

  @override
  List<Object?> get props => [targets];
}
