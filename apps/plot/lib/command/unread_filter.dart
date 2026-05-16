import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/util/shortcut.dart';

import 'base.dart';

/// Toggle the unread-only filter on the current priority's activity
/// feed. Bound to the header [Button.icon] and to a global shortcut
/// scoped to the priority page so the user can switch into and out of
/// a triage view without leaving the editor.
final SingleActivator unreadFilterShortcut =
    platformSingleActivator(LogicalKeyboardKey.keyU, shift: true);

class ToggleUnreadFilter extends Command {
  ToggleUnreadFilter({required bool active})
    : super(
        title: active ? 'Showing unread only' : 'Show unread only',
        icon: FontAwesomeIcons.envelopeDot,
        hoverIcon: FontAwesomeIcons.solidEnvelopeDot,
        eventObject: EventObject.priority,
        eventAction: EventAction.updated,
        shortcut: unreadFilterShortcut,
        on: active,
      );

  /// Used by the priority command list builder, which doesn't otherwise
  /// know the current filter state. Mirrors [ToggleArchivedVisibility]'s
  /// factory pattern: read the bloc once at construction so the command
  /// bar label and the `on` flag reflect live state.
  factory ToggleUnreadFilter.fromContext(BuildContext context) {
    final active =
        context.read<PriorityBloc?>()?.state.unreadFilterActive ?? false;
    return ToggleUnreadFilter(active: active);
  }

  @override
  bool enabled(BuildContext context) {
    final bloc = context.read<PriorityBloc?>();
    if (bloc == null) return false;
    // Allow toggling off even when nothing is unread, so the command
    // is always actionable when the user is in the active state. The
    // bloc handles the no-op case.
    return bloc.state.hasUnreadInFeed || bloc.state.unreadFilterActive;
  }

  @override
  Future<CommandReturn> run(BuildContext context) async {
    context.read<PriorityBloc>().toggleUnreadFilter();
    return const CommandDone();
  }
}
