import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:plot/router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:plot/widget/time.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/state/schedule.dart';

final supabase = Supabase.instance.client;

class EventWidget extends StatelessWidget {
  const EventWidget({required this.event, super.key});

  final ScheduledEvent event;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ScheduleBloc, ScheduleState>(
      builder: (context, scheduleState) => GestureDetector(
        onTap: () {
          if (event.id != null) {
            EventRoute(eventId: event.id!).go(context);
          }
        },
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  width: 80,
                  padding: const EdgeInsets.only(right: 8),
                  alignment: Alignment.centerRight,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        TimeWidget(time: event.at.start),
                        DurationWidget(
                          duration: event.at.duration,
                        ),
                      ])),
              BlocBuilder<PriorityBloc, PriorityState>(
                builder: (context, prioritiesState) => Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (event.context != null)
                        Text(
                          event.context!.name,
                        ),
                      if (event.name != null)
                        Text(
                          event.name!,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// builder: (context, prioritiesState) => Expanded(
//   child: MenuAnchor(
//     builder: (BuildContext context, MenuController controller,
//             Widget? child) =>
//         InkWell(
//       child: Column(
//         crossAxisAlignment: CrossAxisAlignment.start,
//         children: [
//           Text(
//             event.context?.name ?? 'Open',
//           ),
//           if (event.name != null)
//             Text(
//               event.name!,
//               style: const TextStyle(fontWeight: FontWeight.w500),
//             ),
//         ],
//       ),
//       onTap: () {
//         if (controller.isOpen) {
//           controller.close();
//         } else {
//           controller.open();
//         }
//       },
//     ),
//     menuChildren: [
//       if (event.id != null &&
//           event.at.end.isAfter(DateTime.now()))
//         MenuItemButton(
//           leadingIcon: const Icon(Icons.event_busy),
//           onPressed: () {
//             event
//                 .copyWith(
//                   response: EventResponse.declined,
//                 )
//                 .save();
//           },
//           child: const Text('Release time'),
//         ),
//       if (prioritiesState is PriorityLoaded)
//         ...prioritiesState.priorities.map(
//           (priority) => MenuItemButton(
//             onPressed: () {
//               event
//                   .copyWith(
//                     context: priority.context,
//                   )
//                   .save();
//             },
//             child: Text(priority.context?.name ?? 'Other'),
//           ),
//         )
//     ],
//   ),
// ),
