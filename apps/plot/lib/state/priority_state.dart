part of 'priority.dart';

class PriorityState extends Equatable {
  PriorityState({
    required this.context,
    Priority? draft,
    this.pinned = const [],
    this.upcoming = const [],
    this.moreAfter = true,
    List<Priority> past = const [],
    this.moreBefore = true,
  }) : draft = draft ?? Priority(parent: context, draft: true),
       past = [...past, if (context.note != null && !moreBefore) context];

  final Priority context;
  final Priority draft;
  final List<Priority> pinned;
  final List<Priority> upcoming;
  final bool moreAfter;
  final List<Priority> past;
  final bool moreBefore;

  PriorityState copyWith({
    Priority? context,
    Priority? draft,
    List<Priority>? pinned,
    List<Priority>? upcoming,
    bool? moreAfter,
    List<Priority>? past,
    bool? moreBefore,
  }) {
    return PriorityState(
      context: context ?? this.context,
      draft: draft ?? this.draft,
      pinned: pinned ?? this.pinned,
      upcoming: upcoming ?? this.upcoming,
      moreAfter: moreAfter ?? this.moreAfter,
      past: past ?? this.past,
      moreBefore: moreBefore ?? this.moreBefore,
    );
  }

  List<Priority> get priorities {
    return [...upcoming, ...past];
  }

  @override
  List<Object?> get props => [
    context,
    draft,
    pinned,
    upcoming,
    moreAfter,
    past,
    moreBefore,
  ];
}
