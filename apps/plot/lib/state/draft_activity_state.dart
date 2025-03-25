part of 'draft_activity.dart';

class DraftActivityState extends Equatable {
  const DraftActivityState({
    Activity? draft,
  }) : _draft = draft;

  final Activity? _draft;

  bool get loading => _draft == null;
  Activity get draft => _draft!;

  DraftActivityState copyWith({
    Activity? draft,
  }) {
    return DraftActivityState(
      draft: draft ?? this.draft,
    );
  }

  @override
  List<Object?> get props => [
        _draft,
      ];
}
