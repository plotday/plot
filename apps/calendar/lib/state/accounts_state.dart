part of 'accounts.dart';

final class AccountsState extends Equatable {
  const AccountsState(this.accounts);

  final List<Account> accounts;

  AccountsState copyWith({
    List<Account>? accounts,
  }) {
    return AccountsState(
      accounts ?? this.accounts,
    );
  }

  @override
  List<Object?> get props => [accounts];
}
