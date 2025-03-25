import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';

part 'draft_activity_state.dart';

class DraftActivityBloc extends Cubit<DraftActivityState> {
  DraftActivityBloc({required PriorityId priorityId})
      : super(DraftActivityState()) {
    Activity.getDraft(priorityId: priorityId).then((draft) {
      if (draft != null) {
        emit(state.copyWith(
          draft: draft,
        ));
      } else {
        emit(state.copyWith(
          draft: Activity.draft(priorityId: priorityId),
        ));
      }
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
