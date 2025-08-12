part of 'user.dart';

@immutable
sealed class UserState extends Equatable {
  const UserState();

  @override
  List<Object?> get props => [];
}

final class UserLoading extends UserState {
  const UserLoading();
}

final class UserSignedOut extends UserState {
  const UserSignedOut();
}

final class UserReady extends UserState {
  const UserReady(this.user);

  final User user;
}
