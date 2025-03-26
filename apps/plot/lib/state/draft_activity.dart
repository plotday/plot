import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'draft_activity_state.dart';

class DraftActivityBloc extends Cubit<DraftActivityState> {
  DraftActivityBloc({
    required PriorityId priorityId,
    Activity? draft,
  }) : super(DraftActivityState()) {
    Activity.getDraft(priorityId: priorityId).then((previousDraft) {
      if (previousDraft != null) {
        if (draft != null) {
          draft = previousDraft.merge(draft!);
        } else {
          draft = previousDraft;
        }
      }
      emit(state.copyWith(
        draft: draft ?? Activity.draft(priorityId: priorityId),
      ));
    });
  }

  Future<void> updateDraft(Activity activity) async {
    try {
      emit(state.copyWith(
        draft: activity,
      ));
      // TODO debounce save
      await activity.save();
    } catch (e) {
      print(e);
      rethrow;
    }
  }
}
