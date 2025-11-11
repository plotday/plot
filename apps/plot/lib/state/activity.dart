import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:plot/store/store.dart';
import 'package:plot/page/loading.dart';
import 'logging.dart';

part 'activity_state.dart';

class ActivityBloc extends Cubit<ActivityState> {
  ActivityBloc({required Activity activity})
    : _subscriptions = [],
      super(ActivityState(activity: activity)) {
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

  void updateSearch(String search) {
    log.info('Updating search to "$search"');
    emit(state.copyWith(search: search));
    _loadActivities();
  }

  @override
  Future<void> close() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    return super.close();
  }

  Future<void> save(Activity activity) async {
    await activity.save();
  }

  Future<void> add(Activity activity) async {
    emit(
      state.copyWith(
        // Create a new draft
        draft: Activity(
          priority: state.activity.priority,
          parent: state.activity,
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
      Activity.watchOne(state.activity.id).listen((watchedActivity) {
        log.info('Activity updated');
        emit(state.copyWith(activity: watchedActivity));
      }),
    );

    _loadActivities();
  }

  void _loadActivities() {
    log.info('Getting activities for ${state.activity.path}');

    _subscriptions.add(
      Activity.watch(
        priorityId: state.activity.priority.id,
        path: state.activity.path,
        deleted: state.showArchived,
        filter: state.filter.isNotEmpty ? state.filter : null,
        search: state.search.isNotEmpty ? state.search : null,
      ).listen((activities) {
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

class ActivityBlocProvider extends StatefulWidget {
  const ActivityBlocProvider({
    required this.activityId,
    this.activity,
    required this.child,
    super.key,
  });

  final ActivityId activityId;
  final Activity? activity;
  final Widget child;

  @override
  ActivityBlocProviderState createState() => ActivityBlocProviderState();
}

class ActivityBlocProviderState extends State<ActivityBlocProvider> {
  late Future<ActivityBloc> _bloc;

  @override
  void initState() {
    super.initState();
    _bloc =
        (widget.activity != null
                ? Future.value(widget.activity!)
                : Activity.getOne(widget.activityId))
            .then((activity) {
              return ActivityBloc(activity: activity);
            });
  }

  @override
  void didUpdateWidget(ActivityBlocProvider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.activity != null && widget.activity != oldWidget.activity) {
      _bloc.then((bloc) async {
        final activity = widget.activity;
        if (activity == null) return;
        // Create new bloc with updated activity
        bloc.close();
        final newBloc = ActivityBloc(activity: activity);
        setState(() {
          _bloc = Future.value(newBloc);
        });
      });
    } else if (widget.activityId != oldWidget.activityId) {
      _bloc.then((bloc) async {
        bloc.close();
        final activity = await Activity.getOne(widget.activityId);
        final newBloc = ActivityBloc(activity: activity);
        setState(() {
          _bloc = Future.value(newBloc);
        });
      });
    }
  }

  @override
  void dispose() {
    _bloc.then((bloc) => bloc.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _bloc,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const LoadingPage();
        }
        return BlocProvider.value(value: snapshot.data!, child: widget.child);
      },
    );
  }
}
