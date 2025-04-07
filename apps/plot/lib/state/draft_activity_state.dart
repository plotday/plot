part of 'draft_activity.dart';

class DraftActivityState extends Equatable {
  const DraftActivityState({Priority? priority, Activity? draft})
    : _priority = priority,
      _draft = draft;

  final Activity? _draft;
  final Priority? _priority;

  bool get loading => _draft == null || _priority == null;
  Activity get draft => _draft!;
  Priority get priority => _priority!;

  DraftActivityState copyWith({Priority? priority, Activity? draft}) {
    return DraftActivityState(
      priority: priority ?? _priority,
      draft: draft ?? _draft,
    );
  }

  @override
  List<Object?> get props => [_priority, _draft];
}
