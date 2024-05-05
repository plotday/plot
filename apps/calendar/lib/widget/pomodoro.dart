// import 'package:flutter/material.dart';
// import 'package:flutter_bloc/flutter_bloc.dart';
//
// import 'package:plot/util/clock.dart';
// import 'package:plot/state/now.dart';
// import 'time.dart';
//
// class PomodoroWidget extends StatelessWidget implements PreferredSizeWidget {
//   const PomodoroWidget({super.key});
//
//   @override
//   Size get preferredSize => const Size.fromHeight(kToolbarHeight);
//
//   @override
//   Widget build(BuildContext context) {
//     return BlocBuilder<NowBloc, NowState>(
//       builder: (context, state) => StreamBuilder(
//         stream: Clock().seconds,
//         builder: (context, snapshot) => Padding(
//           padding: const EdgeInsets.symmetric(vertical: 4),
//           child: AspectRatio(
//             aspectRatio: 1,
//             child: InkResponse(
//               onTap: () {
//                 switch (state) {
//                   case ContextActive s:
//                     if (s.selected == s.active.context) {
//                       context.read<NowBloc>().add(s.active.isRunning
//                           ? const ContextStopped()
//                           : const ContextResumed());
//                     }
//                   default:
//                     if (state.selected != null) {
//                       context
//                           .read<NowBloc>()
//                           .add(ContextStarted(state.selected!));
//                     }
//                     break;
//                 }
//               },
//               child: Stack(
//                 children: [
//                   Positioned.fill(
//                     child: CircularProgressIndicator(
//                         value: state.progress,
//                         color: state is ContextActive && state.active.isRunning
//                             ? Theme.of(context).colorScheme.primary
//                             : Theme.of(context).colorScheme.secondary,
//                         backgroundColor:
//                             Theme.of(context).colorScheme.outlineVariant),
//                   ),
//                   Center(
//                       child: DurationWidget(
//                           duration:
//                               state.remaining + const Duration(seconds: 59))),
//                 ],
//               ),
//             ),
//           ),
//         ),
//       ),
//     );
//   }
// }
