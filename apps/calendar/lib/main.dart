import 'package:flutter/material.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'env.dart';

import 'signin.dart';

import 'activity/bloc.dart';
import 'activity/activity.dart';
import 'activity/widget/pomodoro.dart';
import 'schedule/bloc.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  runApp(const App());
}

final supabase = Supabase.instance.client;

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveTheme(
      light: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0x002BDD66),
          brightness: Brightness.light,
        ),
      ),
      dark: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0x002BDD66),
          brightness: Brightness.dark,
        ),
      ),
      debugShowFloatingThemeButton: true,
      initial: AdaptiveThemeMode.system,
      builder: (theme, darkTheme) => MaterialApp(
        title: 'Plot',
        theme: theme,
        darkTheme: darkTheme,
        home: MultiBlocProvider(
          providers: [
            BlocProvider(create: (_) => ActivityBloc()),
            BlocProvider(create: (_) => ScheduleBloc()),
          ],
          child: const HomePage(title: 'Plot'),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.title});

  final String title;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: Activity.list(),
        builder: (context, activity) => Scaffold(
              appBar: AppBar(
                backgroundColor: Theme.of(context).colorScheme.inversePrimary,
                title: Text(widget.title),
              ),
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const SigninWidget(),
                    PomodoroTimer(activity: activity.data?.first)
                  ],
                ),
              ),
            ));
  }
}
