import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/widget/widget.dart';
import 'package:plot/store/store.dart';
import 'package:plot/state/onboarding.dart';
import 'package:plot/page/loading.dart';
import 'package:plot/router.dart';

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
                  onTap: () async {
                    context.read<OnboardingBloc>().setLoading(true);
                    final personalPriority = Priority(
                      name: "Personal",
                      order: Order.first(),
                      isDefault: true,
                    );
                    await personalPriority.save();
                    if (!context.mounted) {
                      return;
                    }
                    context.read<OnboardingBloc>().complete();
                    NowRoute().go(context);
                  },
                  loading: state.loading,
                  child: const Text("Get Started"),
                )
              ],
            ),
          ),
        );
      },
    );
  }
}
