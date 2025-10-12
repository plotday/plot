import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'logging.dart';

class _AuthChangeNotifier extends ChangeNotifier {
  void notify() {
    notifyListeners();
  }
}

class RootProvider extends StatefulWidget {
  const RootProvider({required this.builder, super.key});

  @override
  RootProviderState createState() => RootProviderState();

  final Widget Function(RouterConfig<UrlState> routerConfig) builder;
}

class RootProviderState extends State<RootProvider> {
  final UserBloc userBloc = UserBloc();
  final NowBloc nowBloc = NowBloc();
  final PrioritiesBloc prioritiesBloc = PrioritiesBloc();
  final AppRouter router = AppRouter();
  final _authChangeNotifier = _AuthChangeNotifier();

  @override
  void initState() {
    Bloc.observer = BlocLogger();
    super.initState();
  }

  @override
  void dispose() {
    _authChangeNotifier.dispose();
    super.dispose();
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
        listener: (context, state) async {
          switch (state) {
            case UserReady _:
              await prioritiesBloc.start();
              await nowBloc.start();
              _authChangeNotifier.notify();
              break;
            case UserWaitlisted _:
            case UserSignedOut _:
              _authChangeNotifier.notify();
              prioritiesBloc.stop();
              nowBloc.stop();
              break;
            case UserLoading _:
              break;
          }
        },
        child: BlocBuilder<UserBloc, UserState>(
          builder: (context, state) {
            final routerConfig = router.config(
              reevaluateListenable: _authChangeNotifier,
            );
            return switch (state) {
              UserLoading _ => const LoadingPage(),
              UserWaitlisted _ => widget.builder(routerConfig),
              UserSignedOut _ => widget.builder(routerConfig),
              UserReady _ => BlocBuilder<NowBloc, NowState>(
                builder: (context, state) {
                  if (state is NowLoading) {
                    return const LoadingPage();
                  }
                  return widget.builder(routerConfig);
                },
              ),
            };
          },
        ),
      ),
    );
  }
}
