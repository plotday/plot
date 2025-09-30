import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'logging.dart';

class RootProvider extends StatefulWidget {
  const RootProvider({required this.builder, super.key});

  @override
  RootProviderState createState() => RootProviderState();

  final Widget Function(AppRouter router) builder;
}

class RootProviderState extends State<RootProvider> {
  final UserBloc userBloc = UserBloc();
  final NowBloc nowBloc = NowBloc();
  final PrioritiesBloc prioritiesBloc = PrioritiesBloc();
  final AppRouter router = AppRouter();

  @override
  void initState() {
    Bloc.observer = BlocLogger();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => userBloc),
        BlocProvider(create: (_) => nowBloc),
        BlocProvider(create: (_) => prioritiesBloc),
      ],
      child: BlocListener<UserBloc, UserState>(
        listener: (context, state) {
          switch (state) {
            case UserReady _:
              prioritiesBloc.start();
              nowBloc.start();
              break;
            case UserSignedOut _:
              prioritiesBloc.stop();
              nowBloc.stop();
              break;
            case UserLoading _:
              break;
          }
        },
        child: BlocBuilder<UserBloc, UserState>(
          builder: (context, state) {
            return switch (state) {
              UserLoading _ => const LoadingPage(),
              UserSignedOut _ => widget.builder(router),
              UserReady _ => BlocBuilder<NowBloc, NowState>(
                builder: (context, state) {
                  if (state is NowLoading) {
                    return const LoadingPage();
                  }
                  return widget.builder(router);
                },
              ),
            };
          },
        ),
      ),
    );
  }
}
