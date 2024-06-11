import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/model/account.dart';

part 'accounts_state.dart';

class AccountsBloc extends Cubit<AccountsState> {
  AccountsBloc() : super(AccountsState(Account.store.list())) {
    _subscription = Account.store.stream().listen((accounts) {
      emit(state.copyWith(accounts: accounts));
    });
  }

  void dispose() {
    _subscription.cancel();
  }

  late StreamSubscription<List<Account>> _subscription;
}
