part of 'priority.dart';

class PriorityState extends Equatable {
  PriorityState({
    required this.current,
    Priority? draft,
    this.pinned = const [],
    this.active = const [],
    this.moreActive = true,
    this.inactive = const [],
    this.moreInactive = true,
  }) : draft = draft ?? Priority(parent: current, draft: true);

  final Priority current;
  final Priority draft;
  final List<Priority> pinned;
  final List<Priority> active;
  final bool moreActive;
  final List<Priority> inactive;
  final bool moreInactive;

  PriorityState copyWith({
    Priority? current,
    Priority? draft,
    List<Priority>? pinned,
    List<Priority>? active,
    bool? moreActive,
    List<Priority>? inactive,
    bool? moreInactive,
  }) {
    return PriorityState(
      current: current ?? this.current,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      active: active ?? this.active,
      moreActive: moreActive ?? this.moreActive,
      inactive: inactive ?? this.inactive,
      moreInactive: moreInactive ?? this.moreInactive,
    );
  }

  @override
  List<Object?> get props => [
    current,
    draft,
    pinned,
    active,
    moreActive,
    inactive,
    moreInactive,
  ];
}
