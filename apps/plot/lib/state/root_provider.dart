import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/priority.dart';
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

class _LoadingState {
  final bool isSignedIn;
  final Priority? defaultPriority;

  _LoadingState({required this.isSignedIn, this.defaultPriority});
}

class RootProviderState extends State<RootProvider> {
  Future<_LoadingState>? _dataLoading;

  void _onUserStateChange(UserState state) {
    if (state is UserSignedIn) {
      setState(() {
        _dataLoading = Store.get
            .sync()
            .then((_) => Priority.getDefault())
            .then((defaultPriority) => _LoadingState(
                  isSignedIn: true,
                  defaultPriority: defaultPriority,
                ));
      });
    } else {
      setState(() {
        _dataLoading = Future.value(_LoadingState(isSignedIn: false));
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
            if (snapshot.data!.defaultPriority == null) {
              return const Center(child: Text("No default priority"));
            }
            return MultiBlocProvider(
              providers: [
                BlocProvider(
                    create: (_) => NowBloc(
                          defaultPriority: snapshot.data!.defaultPriority!,
                        )),
                BlocProvider(create: (_) => ScheduleBloc()),
                BlocProvider(create: (_) => AccountsBloc()),
                BlocProvider(create: (_) => PrioritiesBloc()),
                BlocProvider(create: (_) => PriorityBloc()),
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
