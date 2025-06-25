import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class AgendaHeader extends StatelessWidget {
  const AgendaHeader({
    this.priority,
    this.context,
    this.event,
    this.date,
    this.now = false,
    this.selected = false,
    this.onHover,
    super.key,
  });

  final Event? event;
  final Date? date;
  final bool now;
  final Priority? priority;
  final Priority? context;

  final bool selected;
  final void Function(bool hovered)? onHover;

  @override
  Widget build(BuildContext context) {
    // Handle date header case
    if (date != null && event == null) {
      return ListTile(
        leading: Text(
          date!.format(format: 'EEE'),
          textAlign: TextAlign.end,
          style: TextStyle(fontSize: context.theme.typography.xs.fontSize),
        ),
        leadingPadding: true,
        body: Text(
          date!.format(format: 'MMM d, yyyy'),
          textAlign: TextAlign.start,
          style: TextStyle(
            color: context.theme.colors.mutedForeground,
            fontSize: context.theme.typography.xs.fontSize,
          ),
        ),
        leadingWidth: 60,
        selected: selected,
        onHover: onHover,
      );
    }

    // Compute priority ancestry from the priority or event
    final currentPriority = priority ?? event?.priority;

    // Handle special case where priorityContext equals priority (display "Other")
    final currentPriorityId = currentPriority?.id;
    final priorityContextId = this.context?.id;
    if (currentPriorityId != null &&
        priorityContextId != null &&
        currentPriorityId == priorityContextId) {
      return ListTile(
        leading: event == null
            ? SizedBox()
            : Text(
                event!.start.toTimeOfDay().isMidnight
                    ? ''
                    : event!.start.toTimeOfDay().format(context),
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: context.theme.colors.mutedForeground,
                  fontSize: context.theme.typography.xs.fontSize,
                ),
              ),
        leadingWidth: 60.0,
        leadingPadding: true,
        selected: selected,
        onHover: onHover,
        body: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          spacing: 8.0,
          children: [
            Expanded(
              child: Text(
                'Other',
                style: context.theme.typography.xs.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
            ),
            if (event != null && event!.duration.inSeconds > 0)
              Text(
                event!.duration.format(),
                style: TextStyle(
                  color: context.theme.colors.mutedForeground,
                  fontSize: context.theme.typography.xs.fontSize,
                ),
              ),
          ],
        ),
      );
    }

    // Compute ancestry relative to priorityContext
    final priorityAncestry = currentPriority?.ancestors(
      context: this.context,
      includeSelf: true,
    );

    // Handle event header case
    return ListTile(
      // icon: PlotIcon.event,
      leading: event == null
          ? SizedBox()
          : Text(
              event!.start.toTimeOfDay().isMidnight
                  ? ''
                  : event!.start.toTimeOfDay().format(context),
              textAlign: TextAlign.end,
              style: TextStyle(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.xs.fontSize,
              ),
            ),
      leadingWidth: 60.0,
      leadingPadding: true,
      command: priorityAncestry?.isNotEmpty == true
          ? ChangeCurrentPriority.byId(priorityAncestry!.last.id)
          : null,
      selected: selected,
      onHover: onHover,
      body: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        spacing: 8.0,
        children: [
          Expanded(child: PriorityLabel(ancestors: priorityAncestry)),
          if (event != null && event!.duration.inSeconds > 0)
            Text(
              event!.duration.format(),
              style: TextStyle(
                color: context.theme.colors.mutedForeground,
                fontSize: context.theme.typography.xs.fontSize,
              ),
            ),
        ],
      ),
    );
  }
}

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
      icon: PlotIcon.event,
      leadingWidth: 60.0,
      leadingPadding: true,
      command: ChangeCurrentEvent(event),
      trailingCommands: [
        ChangeEventPriority(event),
        ChangeEventResponse(event),
      ],
      selected: selected,
      onHover: onHover,
      title: event.name ?? 'Untitled Event',
    );
  }
}
