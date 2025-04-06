import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'draft_activity_state.dart';

class DraftActivityBloc extends Cubit<DraftActivityState> {
  DraftActivityBloc({required Priority priority, Activity? draft})
    : super(DraftActivityState(priority: priority)) {
    _getDraft(priorityId: priority.id, draft: draft);
  }

  DraftActivityBloc.byId({required PriorityId priorityId, Activity? draft})
    : super(DraftActivityState()) {
    _getPriority(priorityId);
    _getDraft(priorityId: priorityId, draft: draft);
  }

  void _getDraft({required PriorityId priorityId, Activity? draft}) async {
    Activity.getDraft(priorityId: priorityId).then((previousDraft) {
      if (previousDraft != null) {
        if (draft != null) {
          draft = previousDraft.merge(draft!);
        } else {
          draft = previousDraft;
        }
      }
      emit(
        state.copyWith(draft: draft ?? Activity.draft(priorityId: priorityId)),
      );
    });
  }

  Future<void> _getPriority(PriorityId priorityId) async {
    await Priority.get(priorityId).then((priority) {
      emit(state.copyWith(priority: priority));
    });
  }

  Future<void> updateDraft(Activity activity) async {
    try {
      emit(state.copyWith(draft: activity));
      // TODO debounce save
      await activity.save();
    } catch (e) {
      print(e);
      rethrow;
    }
    if (activity.priorityId != state.priority.id) {
      _getPriority(activity.priorityId);
    }
  }
}
