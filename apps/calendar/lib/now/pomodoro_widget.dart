import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'bloc.dart';
import '../util/clock.dart';
import '../util/duration_widget.dart';

class PomodoroWidget extends StatelessWidget implements PreferredSizeWidget {
  const PomodoroWidget({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NowBloc, NowState>(
      builder: (context, state) => StreamBuilder(
        stream: Clock().seconds,
        builder: (context, snapshot) => AspectRatio(
          aspectRatio: 1,
          child: InkResponse(
            onTap: () {
              switch (state) {
                case ActivityActive s:
                  if (s.selected == s.active.activity) {
                    context.read<NowBloc>().add(s.active.isRunning
                        ? const ActivityStopped()
                        : const ActivityResumed());
                  }
                default:
                  if (state.selected != null) {
                    context
                        .read<NowBloc>()
                        .add(ActivityStarted(state.selected!));
                  }
                  break;
              }
            },
            child: Stack(
              children: [
                Positioned.fill(
                    child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: CircularProgressIndicator(
                      value: state.progress,
                      color: state is ActivityActive && state.active.isRunning
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.secondary,
                      backgroundColor:
                          Theme.of(context).colorScheme.outlineVariant),
                )),
                Center(
                    child: DurationWidget(
                        duration: state.remaining +
                            const Duration(hours: 1, seconds: 59))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

                  // Column(
                  // children: [
                  //   IconButton(
                  //     icon: const Icon(Icons.expand_less),
                  //     tooltip: 'Reduce time',
                  //     onPressed: () {
                  //       context.read<NowBloc>().add(ActivityTimeDecreased());
                  //     },
                  //   ),
                  // IconButton(
                  //   icon: const Icon(Icons.expand_more),
                  //   tooltip: 'Add time',
                  //   onPressed: () {
                  //     context.read<NowBloc>().add(ActivityTimeIncreased());
                  //   },
                  // ),
