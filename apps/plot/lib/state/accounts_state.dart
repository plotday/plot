part of 'accounts.dart';

@immutable
final class AccountsState extends Equatable {
  AccountsState(List<Account> accounts) 
    : accounts = accounts.isNotEmpty ? List.unmodifiable(accounts) : accounts;

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
