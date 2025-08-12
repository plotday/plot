import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'logging.dart';

part 'activity_state.dart';

class ActivityBloc extends Cubit<ActivityState> {
  ActivityBloc({required Priority priority, Activity? activity, Event? event})
    : _subscriptions = [],
      super(
        ActivityState(context: priority, activity: activity, event: event),
      ) {
    _loadActivity();
  }

  void toggleShowArchived() {
    final newShowArchived = !state.showArchived;
    log.info('Toggling showArchived to $newShowArchived');
    emit(state.copyWith(showArchived: newShowArchived));
    _loadActivities();
  }

  void updateFilter(List<Tag> filter) {
    log.info('Updating filter to $filter');
    emit(state.copyWith(filter: filter));
    _loadActivities();
  }

  @override
  Future<void> close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    return super.close();
  }

  PriorityId get currentId => state.context.id;

  Future<void> save(Activity activity) async {
    await activity.save();
  }

  Future<void> add(Activity activity) async {
    emit(
      state.copyWith(
        // Create a new draft
        draft: Activity(
          priority: state.context,
          parent: state.activity,
          parentEvent: state.event,
          draft: true,
        ),
      ),
    );
    activity = activity.copyWith(draft: false);
    await activity.save();
  }

  void _loadActivity() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    
    _subscriptions.add(
      Priority.watchOne(state.context.id).listen((priority) {
        log.info('Priority updated');
        emit(state.copyWith(context: priority));
      }),
    );

    if (state.activity != null) {
      _subscriptions.add(
        Activity.watchOne(state.activity!.id).listen((watchedActivity) {
          log.info('Activity updated');
          emit(state.copyWith(activity: watchedActivity));
        }),
      );
    }

    if (state.event != null) {
      _subscriptions.add(
        Event.watchOne(state.event!.id).listen((watchedEvent) {
          log.info('Event updated');
          emit(state.copyWith(event: watchedEvent));
        }),
      );
    }

    _loadActivities();
  }


  void _loadActivities() {
    log.info(
      'Getting activities for ${state.activity?.path ?? state.event?.path}',
    );
    
    _subscriptions.add(
      Activity.watch(
        priorityPath: state.context.path,
        path: state.activity?.path ?? state.event?.path,
        deleted: state.showArchived,
        filter: state.filter.isNotEmpty ? state.filter : null,
      ).listen((activities) {
        log.info(
          'Got activities for ${state.activity?.path ?? state.event?.path}',
        );
        
        // Sort activities by creation/completion date in reverse chronological order
        final sortedActivities = List<Activity>.from(activities);
        sortedActivities.sort((a, b) {
          final aDate = a.doneAt ?? a.createdAt;
          final bDate = b.doneAt ?? b.createdAt;
          return bDate.compareTo(aDate); // Reverse chronological order
        });

        // Group activities by date for headers
        final groupedActivities = <ActivityDateGroup>[];
        Date? currentDate;
        List<Activity> currentGroup = [];

        for (final activity in sortedActivities) {
          final activityDate = (activity.doneAt ?? activity.createdAt).toDate();
          
          if (currentDate != activityDate) {
            // Save previous group if it exists
            if (currentDate != null && currentGroup.isNotEmpty) {
              groupedActivities.add(
                ActivityDateGroup(date: currentDate, activities: currentGroup),
              );
            }
            
            // Start new group
            currentDate = activityDate;
            currentGroup = [activity];
          } else {
            currentGroup.add(activity);
          }
        }
        
        // Add the last group
        if (currentDate != null && currentGroup.isNotEmpty) {
          groupedActivities.add(
            ActivityDateGroup(date: currentDate, activities: currentGroup),
          );
        }

        emit(state.copyWith(activityGroups: groupedActivities));
      }),
    );
  }

  final List<StreamSubscription<void>> _subscriptions;
}