import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';
import 'package:plot/command/command.dart';

class GetStarted extends Command {
  const GetStarted()
      : super(
          title: 'Get Started',
        );

  @override
  Future<CommandReturn?> run(BuildContext context) async {
    context.read<OnboardingBloc>().setLoading(true);
    final personalPriority = Priority(
      name: "Personal",
      order: Order.first(),
      isDefault: true,
    );
    await personalPriority.save();
    if (!context.mounted) {
      return null;
    }
    context.read<OnboardingBloc>().complete();
    NowRoute().go(context);
    return null;
  }
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OnboardingBloc, OnboardingState>(
      builder: (context, state) {
        if (state is! OnboardingProgressState) {
          return const LoadingPage();
        }
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Welcome to Plot!"),
                Button(
                  GetStarted(),
                  loading: state.loading,
                )
              ],
            ),
          ),
        );
      },
    );
  }
}
