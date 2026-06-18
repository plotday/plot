import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:plot/command/base.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/widget/icon.dart';

/// Pure tri-state decision for [ToggleUnreadFilter].
///
/// Extracted so the mapping from (hasUnread, active) → command properties
/// can be unit-tested without constructing a [PriorityBloc].
({IconData icon, String title, bool enabled, bool on}) unreadToggleState({
  required bool hasUnread,
  required bool active,
}) {
  if (!hasUnread) {
    return (
      icon: PlotIcon.envelopeAllRead,
      title: 'No unread threads',
      enabled: false,
      on: false,
    );
  }
  if (active) {
    return (
      icon: PlotIcon.envelopeUnread,
      title: 'Show all threads',
      enabled: true,
      on: true,
    );
  }
  return (
    icon: PlotIcon.envelopeUnread,
    title: 'Show only unread threads',
    enabled: true,
    on: false,
  );
}

/// Tri-state header toggle for the unread-only feed filter.
///
/// - no unread (`!hasUnread`): icon `envelopeAllRead`, disabled,
///   tooltip "No unread threads".
/// - unread present, filter off: icon `envelopeUnread`,
///   tooltip "Show only unread threads", tap → `updateUnreadFilter(true)`.
/// - filter on: icon `envelopeUnread` in highlight colour
///   (`selected: true`), tooltip "Show all threads",
///   tap → `updateUnreadFilter(false)`.
class ToggleUnreadFilter extends Command {
  ToggleUnreadFilter._({
    required bool hasUnread,
    required bool active,
  }) : _hasUnread = hasUnread,
       super(
         title: unreadToggleState(hasUnread: hasUnread, active: active).title,
         icon: unreadToggleState(hasUnread: hasUnread, active: active).icon,
         on: unreadToggleState(hasUnread: hasUnread, active: active).on,
         eventObject: EventObject.filter,
         eventAction: EventAction.filtered,
       );

  factory ToggleUnreadFilter({required BuildContext context}) {
    final state = context.read<PriorityBloc>().state;
    return ToggleUnreadFilter._(
      hasUnread: state.hasUnread,
      active: state.unreadFilterActive,
    );
  }

  final bool _hasUnread;

  @override
  bool enabled(BuildContext context) => _hasUnread;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    final bloc = context.read<PriorityBloc>();
    bloc.updateUnreadFilter(!bloc.state.unreadFilterActive);
    return const CommandDone();
  }
}
