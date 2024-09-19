part of 'accounts.dart';

final class AccountsState extends Equatable {
  const AccountsState(this.accounts);

  final List<AccountWithCalendars> accounts;

  AccountsState copyWith({
    List<AccountWithCalendars>? accounts,
  }) {
    return AccountsState(
      accounts ?? this.accounts,
    );
  }

  @override
  List<Object?> get props => [accounts];
}
