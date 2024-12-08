import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import 'state/user.dart';
import 'router.dart';
import 'widget/app.dart';
import 'widget/layout.dart';
import 'widget/spinner.dart';

class App extends StatefulWidget {
  static Future<void> init() async {
    await AppWidget.init();
  }

  const App({super.key});

  @override
  AppState createState() => AppState();
}

class AppState extends State<App> with WidgetsBindingObserver {
  late Future<GoRouter> router;

  @override
  void initState() {
    super.initState();
    router = Layout.getLayout(context).then((layout) => getRouter(layout));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: router,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          print(snapshot.error);
          print(snapshot.stackTrace);
          return const Center(child: Text("Something went wrong"));
        }
        if (!snapshot.hasData) {
          return const Center(child: Spinner());
        }
        return BlocProvider<UserBloc>(
          create: (_) => UserBloc(),
          child: BlocListener<UserBloc, UserState>(
            listener: (context, state) {
              snapshot.data?.refresh();
            },
            child: AppWidget(
              routerConfig: snapshot.data,
            ),
          ),
        );
      },
    );
  }
}
