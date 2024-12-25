import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/state/activity.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/spinner.dart';

class BlocErrorLogger extends BlocObserver {
  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    print('onError -- ${bloc.runtimeType}, $error');
    super.onError(bloc, error, stackTrace);
  }
}

class RootProvider extends StatefulWidget {
  const RootProvider({required this.child, super.key});

  @override
  RootProviderState createState() => RootProviderState();

  final Widget child;
}

class RootProviderState extends State<RootProvider> {
  Future<bool>? _dataLoading;

  void _onUserStateChange(UserState state) {
    if (state is UserSignedIn) {
      print("RootProviderState._onUserStateChange IN");
      setState(() {
        _dataLoading = Store.get.sync().then((_) => true);
      });
    } else {
      print("RootProviderState._onUserStateChange OUT");
      setState(() {
        _dataLoading = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    Bloc.observer = BlocErrorLogger();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<UserBloc>(
      create: (_) => UserBloc(),
      child: BlocListener<UserBloc, UserState>(
        listener: (context, state) {
          _onUserStateChange(state);
        },
        child: FutureBuilder(
          future: _dataLoading,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              print(snapshot.error);
              print(snapshot.stackTrace);
              return const Center(child: Text("Error loading data"));
            }
            if (!snapshot.hasData) {
              return const Center(child: Spinner());
            }
            return MultiBlocProvider(
              providers: [
                BlocProvider(create: (_) => NowBloc()),
                BlocProvider(create: (_) => ScheduleBloc()),
                BlocProvider(create: (_) => AccountsBloc()),
                BlocProvider(create: (_) => ActivityBloc()),
              ],
              child: widget.child,
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}
