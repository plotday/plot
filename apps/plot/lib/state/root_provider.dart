import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/page/loading.dart';

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
  @override
  void initState() {
    super.initState();
    Bloc.observer = BlocErrorLogger();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<UserBloc>(
      create: (_) => UserBloc(),
      child: BlocBuilder<UserBloc, UserState>(
        builder: (context, state) {
          return switch (state) {
            UserLoading _ => const LoadingPage(),
            UserSignedOut _ => widget.child,
            UserSignedIn _ => MultiBlocProvider(
                providers: [
                  BlocProvider(create: (_) => OnboardingBloc()),
                  BlocProvider(create: (_) => AccountsBloc()),
                  BlocProvider(create: (_) => PrioritiesBloc()),
                  BlocProvider(create: (_) => NowBloc()),
                  BlocProvider(create: (_) => ScheduleBloc()),
                ],
                child: BlocBuilder<NowBloc, NowState>(
                  builder: (context, state) {
                    if (state is NowLoadingState) {
                      return const LoadingPage();
                    }
                    return widget.child;
                  },
                ),
              ),
          };
        },
      ),
    );
  }
}
