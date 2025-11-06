// class PickEventResponse extends ShowActions {
//   PickEventResponse(Event event)
//     : super(
//         title: 'Change Response',
//         icon: PlotIcon.event,
//         actions: (context) => Future.value(
//           Actions(
//             prompt: 'Select response',
//             groups: [
//               StaticActionGroup(
//                 title: 'Response Options',
//                 actions: [
//                   ChangeEventResponse(
//                     event,
//                     EventResponse.accepted,
//                     title: 'Accepted',
//                     subtitle: 'Accept this event',
//                     icon: PlotIcon.done,
//                   ),
//                   ChangeEventResponse(
//                     event,
//                     EventResponse.declined,
//                     title: 'Declined',
//                     subtitle: 'Decline this event',
//                     icon: PlotIcon.archived,
//                   ),
//                   ChangeEventResponse(
//                     event,
//                     EventResponse.tentative,
//                     title: 'Tentative',
//                     subtitle: 'Maybe attend this event',
//                     icon: PlotIcon.priority,
//                   ),
//                 ],
//               ),
//             ],
//           ),
//         ),
//       );
// }
//
// class ChangeEventResponse extends Action {
//   ChangeEventResponse(
//     this.event,
//     this.response, {
//     required super.title,
//     super.subtitle,
//     super.icon,
//   });
//   final Event event;
//   final EventResponse response;
//
//   @override
//   Future<ActionReturn> run(BuildContext context) async {
//     await event
//         .copyWith(
//           response: Value(response),
//           archivedAt: response == EventResponse.declined
//               ? Value(DateTime.now())
//               : Value(null),
//         )
//         .save();
//     return const ActionDone();
//   }
// }
