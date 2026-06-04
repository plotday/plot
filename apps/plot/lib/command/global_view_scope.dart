import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'command.dart';
import 'package:plot/analytics/tracker.dart';
import 'package:plot/state/priority.dart';
import 'package:plot/store/store.dart';

/// Narrow the active global view (an active search or filter) to a focus, or
/// back to "Everything" ([scope] is null).
///
/// Unlike [ChangeCurrentPriority], this does NOT navigate the router or touch
/// [NowBloc] — it only re-scopes the active global view in place via
/// [PriorityBloc.setGlobalViewScope], so the search text and filter chips stay
/// active. Used by the global-view sidebar's Everything / Inbox / focus tiles.
class SetGlobalViewScope extends Command {
  SetGlobalViewScope(this.scope, {String? title})
    : super(
        title: title ?? (scope == null ? 'Everything' : scope.title),
        eventObject: EventObject.filter,
        eventAction: EventAction.filtered,
      );

  /// The focus to narrow to. `null` = Everything (the full global result set);
  /// the root = Inbox (unfiled threads only).
  final Priority? scope;

  @override
  Future<CommandReturn> run(BuildContext context) async {
    try {
      context.read<PriorityBloc>().setGlobalViewScope(scope);
    } on ProviderNotFoundException {
      // No PriorityBloc in scope — nothing to narrow.
    }
    return const CommandDone();
  }
}
