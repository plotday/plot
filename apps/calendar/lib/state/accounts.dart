import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'accounts_state.dart';

class AccountsBloc extends Cubit<AccountsState> {
  AccountsBloc() : super(const AccountsState([])) {
    _subscription = Accounts.watchWithCalendars().listen((accounts) {
      emit(state.copyWith(accounts: accounts));
    });
  }

  void dispose() {
    _subscription.cancel();
  }

  late StreamSubscription<List<AccountWithCalendars>> _subscription;
}
