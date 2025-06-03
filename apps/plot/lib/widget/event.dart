import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';

class EventWidget extends StatelessWidget {
  const EventWidget({
    required this.event,
    this.context,
    this.selected = false,
    this.onHover,
    super.key,
  });

  final Event event;

  /// Display priority relative to this priority.
  final Priority? context;

  final bool selected;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      onHover: onHover,
      header:
          event.priorityId != null && event.priorityId != this.context?.id
              ? PriorityLabel(
                priority: event.priority,
                context: this.context,
                onlyAncestors: true,
              )
              : null,
      body: event.name == null ? Squiggle() : null,
      title: event.name?.isNotEmpty == true ? event.name! : null,
    );
    // GestureDetector(
    //   onTap: () => onSelect(),
    //   child: Padding(
    //     padding: const EdgeInsetsDirectional.all(4),
    //     child: Row(
    //       crossAxisAlignment: CrossAxisAlignment.start,
    //       children: [
    //         Container(
    //           width: 68,
    //           alignment: Alignment.topRight,
    //           child: Column(
    //             crossAxisAlignment: CrossAxisAlignment.end,
    //             children: [
    //               if (!event.at.start.toTimeOfDay().isMidnight)
    //                 TimeWidget(time: event.at.start),
    //               if (!event.at.start.toTimeOfDay().isMidnight &&
    //                   !event.at.end.toTimeOfDay().isMidnight) ...[
    //                 const SizedBox(height: 4),
    //                 DurationText(
    //                   duration: !(event.at.start.toTimeOfDay().isMidnight ||
    //                           event.at.end.toTimeOfDay().isMidnight)
    //                       ? event.at.duration
    //                       : Duration.zero,
    //                 ),
    //               ],
    //             ],
    //           ),
    //         ),
    //         const SizedBox(width: 8),
    //         Expanded(
    //           child: Column(
    //             crossAxisAlignment: CrossAxisAlignment.stretch,
    //             children: [
    //               if (event.name == null)
    //                 const SizedBox(
    //                   height: 16,
    //                   child: Squiggle(),
    //                 ),
    //               if (event.name != null)
    //                 Text(
    //                   event.name!,
    //                   style: const TextStyle(
    //                       fontWeight: FontWeight.w500, height: 1.0),
    //                   overflow: TextOverflow.ellipsis,
    //                 ),
    //               if (event.name != null) const SizedBox(height: 4),
    //             ],
    //           ),
    //         ),
    //       ],
    //     ),
    //   ),
    // );
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
