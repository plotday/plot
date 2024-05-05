part of 'context.dart';

final class ContextState extends Equatable {
  const ContextState(this.contexts);

  final List<Context> contexts;

  ContextState copyWith({
    List<Context>? contexts,
  }) {
    return ContextState(
      contexts ?? this.contexts,
    );
  }

  @override
  List<Object?> get props => [contexts];
}
