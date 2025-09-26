import 'package:flutter/widgets.dart';

import 'package:plot/store/store.dart';
import 'package:plot/widget/widget.dart';
import 'package:plot/command/command.dart';

class DayHeader extends StatelessWidget {
  const DayHeader({
    this.date,
    this.now = false,
    this.selected = false,
    super.key,
  });

  final Date? date;
  final bool now;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      body: Align(
        alignment: Alignment.center,
        child: Text(
          date!.format(format: 'EEEE, MMMM d, yyyy'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.theme.colors.mutedForeground,
            fontSize: context.theme.typography.xs.fontSize,
          ),
        ),
      ),
      selected: selected,
    );
  }
}

class AgendaHeader extends StatelessWidget {
  const AgendaHeader({
    this.priority,
    this.context,
    this.activity,
    this.now = false,
    this.selected = false,
    super.key,
  });

  final Activity? activity;
  final bool now;
  final Priority? priority;
  final Priority? context;

  final bool selected;

  @override
  Widget build(BuildContext context) {
    // Compute priority ancestry from the priority or activity
    final currentPriority = priority ?? activity?.priority;

    // Compute ancestry relative to priorityContext
    final priorityAncestry = currentPriority?.ancestors(
      context: this.context,
      includeSelf: true,
    );

    return ListTile(
      command: activity?.draft == false
          ? ChangeCurrentActivity(activity!)
          : priorityAncestry?.isNotEmpty == true
          ? CommandWrapper(
              OpenPriority.byId(priorityAncestry!.last.id),
              icon: Value(null),
            )
          : null,
      selected: selected,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8.0,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            spacing: 8.0,
            children: [
              if (activity != null) ...[
                Text(
                  activity!.at?.start?.toTimeOfDay().isMidnight == true
                      ? ''
                      : activity!.at?.start?.toTimeOfDay().format(context) ?? '',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: context.theme.colors.mutedForeground,
                    fontSize: context.theme.typography.xs.fontSize,
                  ),
                ),
                if (activity!.duration?.inSeconds != null && activity!.duration!.inSeconds > 0 &&
                    !(activity!.draft &&
                        activity!.at?.end == activity!.at?.start?.startOfDay.addDays(1)))
                  Text(
                    activity!.duration!.format(),
                    style: TextStyle(
                      color: context.theme.colors.mutedForeground,
                      fontSize: context.theme.typography.xs.fontSize,
                    ),
                  ),
              ],
              Expanded(
                child: currentPriority?.id == this.context?.id
                    ? Text(
                        'Other',
                        style: DefaultTextStyle.of(context).style.copyWith(
                          color: context.theme.colors.mutedForeground,
                          fontSize: context.theme.typography.xs.fontSize,
                        ),
                      )
                    : PriorityLabel(ancestors: priorityAncestry),
              ),
            ],
          ),
          if (activity?.title != null)
            Row(
              spacing: 4.0,
              children: [
                Icon(PlotIcon.event, size: 12, color: context.colour.muted),
                Text(
                  activity!.title ?? 'Untitled Activity',
                  textAlign: TextAlign.start,
                  style: DefaultTextStyle.of(context).style.copyWith(
                    color: context.theme.colors.foreground,
                    fontSize: context.theme.typography.xs.fontSize,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
