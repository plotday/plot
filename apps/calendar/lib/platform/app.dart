import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'style.dart';
import 'app_mac.dart';
import 'app_material.dart';
import 'package:plot/state/user.dart';
import 'package:plot/router.dart';

class App extends StatelessWidget {
  static Future<void> init() async {
    switch (style) {
      case Style.mac:
        await MacApp.init();
      default:
        break;
    }
  }

  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final router = getRouter(context);
    final app = switch (style) {
      Style.mac => MacApp(router),
      Style.ios => const Text("TODO"),
      Style.material => MaterialApp(router),
      Style.windows => const Text("TODO"),
    };
    return BlocProvider<UserBloc>(
        create: (_) => UserBloc(),
        child: BlocListener<UserBloc, UserState>(
          listener: (context, state) {
            router.refresh();
          },
          child: app,
        ));
  }
}
