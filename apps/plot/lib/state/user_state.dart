part of 'user.dart';

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

final class UserSignedIn extends UserState {
  const UserSignedIn(this.user);

  final User user;
}
