part of 'context.dart';

final class ContextState extends Equatable {
  const ContextState(this.contexts, {this.current});

  final List<Context> contexts;
  final Context? current;

  ContextState copyWith({
    List<Context>? contexts,
    Context? current,
  }) {
    return ContextState(
      contexts ?? this.contexts,
      current: current ?? this.current,
    );
  }

  @override
  List<Object?> get props => [contexts];
}
