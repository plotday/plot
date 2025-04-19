import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/schedule.dart';
import 'package:plot/state/accounts.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/page/sign_in.dart';
import 'logging.dart';

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
    Bloc.observer = BlocLogger();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<UserBloc>(
      create: (_) => UserBloc(),
      child: BlocBuilder<UserBloc, UserState>(
        builder: (context, state) {
          return switch (state) {
            UserLoading _ => const LoadingPage(),
            UserSignedOut _ => SignInPage(),
            UserReady _ => MultiBlocProvider(
                providers: [
                  BlocProvider(create: (_) => AccountsBloc()),
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
