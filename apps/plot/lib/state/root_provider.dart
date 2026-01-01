import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/cli_args.dart';
import 'package:plot/command/command.dart';
import 'package:plot/command/page_link.dart';
import 'package:plot/state/user.dart';
import 'package:plot/state/now.dart';
import 'package:plot/state/priorities.dart';
import 'package:plot/state/theme.dart';
import 'package:plot/util/theme_color.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'package:plot/store/store.dart';
import 'package:plot/widget/root_menu_bar.dart';
import 'logging.dart';

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
  late final RouterConfig<UrlState> routerConfig;

  void Function()? _nowBlocListener;
  StreamSubscription<Priority>? _contextPriorityListener;
  bool _hasNavigatedToCliUrl = false;

  @override
  void initState() {
    Bloc.observer = BlocLogger();
    routerConfig = router.config(
      reevaluateListenable: ReevaluateListenable.stream(userBloc.stream),
    );
    super.initState();
  }

  @override
  void dispose() {
    _nowBlocListener?.call();
    _contextPriorityListener?.cancel();
    super.dispose();
  }

  void _setupNowBlocListener(ThemeBloc themeBloc) {
    _nowBlocListener?.call();
    _nowBlocListener = nowBloc.stream.listen((state) {
      if (state is NowLoaded && state.context != null) {
        themeBloc.setPriorityColor(state.context!.displayColor);

        // Set up Priority watcher to detect color changes
        _contextPriorityListener?.cancel();
        _contextPriorityListener = Priority.watchOne(state.context!.id).listen((
          priority,
        ) {
          themeBloc.setPriorityColor(priority.displayColor);
        });
      } else {
        // No context, cancel Priority listener
        _contextPriorityListener?.cancel();
        _contextPriorityListener = null;
      }
    }).cancel;
  }

  void _teardownNowBlocListener() {
    _nowBlocListener?.call();
    _nowBlocListener = null;
    _contextPriorityListener?.cancel();
    _contextPriorityListener = null;
  }

  void _navigateToUrl(BuildContext navigateContext, String url) {
    log.info('Navigating to CLI URL: $url');
    // Use the OpenPageLink command for navigation
    navigateContext.run(OpenPageLink(url));
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
          final themeBloc = context.read<ThemeBloc>();

          switch (state) {
            case UserReady _:
              await prioritiesBloc.start();
              await nowBloc.start();
              _setupNowBlocListener(themeBloc);

              // Navigate to CLI URL if provided (only once)
              if (context.mounted &&
                  !_hasNavigatedToCliUrl &&
                  CliArgs.url != null) {
                _hasNavigatedToCliUrl = true;
                final url = CliArgs.url!;
                _navigateToUrl(context, url);
              }
              break;
            case UserSignedOut _:
              _teardownNowBlocListener();
              prioritiesBloc.stop();
              nowBloc.stop();
              // Set theme to Catalyst when signed out
              themeBloc.setPriorityColor(ThemeColor(0));
              await router.replaceAll([SignInRoute()]);
              // Wait for widget tree to update and dispose old widgets before removing Store
              await WidgetsBinding.instance.endOfFrame;
              await Store.stop();
              // Clear actorId after all blocs and store are stopped to prevent
              // race conditions with streams accessing actorId during cleanup
              Base.clearActorId();
              break;
            case UserWaitlisted _:
              await router.replaceAll([InvitationRoute()]);
              break;
            case UserPasswordRequired _:
              await router.replaceAll([PasswordSetupRoute()]);
              break;
            default:
              break;
          }
        },
        child: RootMenuBar(
          child: BlocBuilder<UserBloc, UserState>(
            builder: (context, state) {
              return switch (state) {
                UserLoading _ => const LoadingPage(),
                UserWaitlisted _ => widget.builder(routerConfig),
                UserPasswordRequired _ => widget.builder(routerConfig),
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
      ),
    );
  }
}
