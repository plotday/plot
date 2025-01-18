part of 'store.dart';

typedef ActivityId = Uuid;

@DataClassName('ActivityRow')
class Activities extends UuidStoreTable with DraftTable, DeletableTable {
  BlobColumn get userId => blob()
      .clientDefault(() => Uuid.generate().toBytes())
      .map(const UuidConverter())();
  TextColumn get body => text()();
  RealColumn get order => real()
      .clientDefault(() => Order.first().value)
      .map(const OrderConverter())();
  DateTimeColumn get orderedAt => dateTime()
      .withDefault(currentDateAndTime)
      .map(const LocalDateTimeConverter())();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  BlobColumn get priorityId => blob()
      .nullable()
      .map(const UuidConverter())
      .references(Priorities, #id)();
  DateTimeColumn get doAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

class ActivitiesBase extends BaseTable {
  ActivitiesBase({
    super.limit,
    super.filterName,
  }) : super(
          table: 'activity_x',
          writeTable: 'activity',
          name: 'activities',
          order: 'order_x',
          ascending: false,
        );

  @override
  Insertable<DataClass> fromBase(Map<String, dynamic> json) =>
      ActivityRow.fromJson(json);
}

class PriorityActivitiesBase extends ActivitiesBase {
  PriorityActivitiesBase(this.priorityPath)
      : super(
          filterName: priorityPath?.toString(),
          limit: 40,
        );

  final Path? priorityPath;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    if (priorityPath == null) return query;
    return query.filter('priority_path', 'cs', priorityPath);
  }
}

class ActiveActivitiesBase extends ActivitiesBase {
  ActiveActivitiesBase(this.until);

  final DateTime until;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    return query.lt('do_at', until).not('done_at', 'is', null);
  }
}

class Activity extends ActivityRow implements Comparable<Activity> {
  static TableInfo<Activities, ActivityRow> get table => Store.get.activities;

  static Future<void> push() => Store.get.push(table, ActivitiesBase());
  static Future<bool> pull() async =>
      Store.get.pull(PullType.updates, table, ActivitiesBase());
  static Future<bool> pullPriority(Path? priorityPath,
          {bool more = false}) async =>
      Store.get.pull(more ? PullType.more : PullType.initial, table,
          PriorityActivitiesBase(priorityPath));
  static Future<bool> pullActive(DateTime until) async =>
      Store.get.pull(PullType.all, table, ActiveActivitiesBase(until));
  static bool hasMorePriority(Path? priorityPath) =>
      Store.get.hasMore(PriorityActivitiesBase(priorityPath));

  static Future<Activity> get(ActivityId id) async {
    return await (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes())))
        .getSingle()
        .then(Activity.fromStore);
  }

  static Stream<List<Activity>> watchPriority(Priority? priority,
      {bool? deleted = false}) {
    pullPriority(priority?.path);
    final query = Store.get.select(table);
    if (priority == null) {
      query.where((t) => t.priorityId.isNull());
    } else {
      query.where((t) => t.priorityId.equals(priority.id.toBytes()));
    }
    if (deleted != null) {
      query.where(
          (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull());
    }

    query.orderBy([
      (t) => OrderingTerm.desc(t.pinned),
      (t) => OrderingTerm(
            expression: const CustomExpression<DateTime>(
                'CASE WHEN do_at IS NOT NULL AND done_at IS NULL AND do_at <= CURRENT_TIMESTAMP THEN do_at ELSE NULL END'),
            mode: OrderingMode.asc,
          ),
      (t) => OrderingTerm.desc(t.order)
    ]);

    return query
        .watch()
        .map((rows) => rows.map((row) => Activity.fromStore(row)).toList());
  }

  // Stream of items that are currently active, and will become active before
  // the end of the current day.
  static Stream<List<Activity>> watchActive({bool? deleted = false}) {
    return Date.current().switchMap((date) {
      pullActive(date.toEnd());
      final query = Store.get.select(table)
        ..where((t) =>
            t.draft.equals(false) &
            t.doAt.isSmallerThanValue(date.toEnd()) &
            t.doneAt.isNull());
      if (deleted != null) {
        query.where(
            (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull());
      }
      return query
          .watch()
          .map((rows) => rows.map((row) => Activity.fromStore(row)).toList());
    });
  }

  factory Activity.draft({
    required PriorityId? priorityId,
  }) {
    final id = Uuid.generate();
    final now = DateTime.now();
    return Activity.fromStore(ActivityRow(
      id: id,
      priorityId: priorityId,
      userId: Base.userId,
      createdAt: now,
      updatedAt: now,
      draft: true,
      body: "",
      order: Order.first(),
      orderedAt: now,
      private: true,
      pinned: false,
    ));
  }

  Activity.fromStore(ActivityRow row)
      : super(
          priorityId: row.priorityId,
          body: row.body,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          deletedAt: row.deletedAt,
          doAt: row.doAt,
          doneAt: row.doneAt,
          draft: row.draft,
          id: row.id,
          order: row.order,
          orderedAt: row.orderedAt,
          pinned: row.pinned,
          private: row.private,
          userId: row.userId,
        );

  @override
  Activity copyWith({
    ActivityId? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    Value<DateTime?> deletedAt = const Value.absent(),
    bool? draft,
    Uuid? userId,
    String? body,
    Order? order,
    DateTime? orderedAt,
    bool? root,
    bool? pinned,
    bool? private,
    ActivityId? activityId,
    Value<PriorityId?> priorityId = const Value.absent(),
    Value<DateTime?> doAt = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
  }) {
    final publish = this.draft && draft == false;
    if (doAt.present && doAt.value != null) {
      doneAt = const Value(null);
      order ??= Order.last();
      pinned = false;
    } else if (pinned == true) {
      doAt = const Value(null);
      order ??= Order.last();
    }
    if ((((doneAt.present && doneAt.value != null) ||
                (doAt.present && doAt.value == null)) &&
            !(pinned ?? this.pinned)) ||
        pinned == false) {
      order ??= Order.first();
    }
    if (publish) {
      order ??= Order.first();
    }
    return Activity.fromStore(super.copyWith(
      id: id ?? this.id,
      createdAt: publish ? DateTime.now() : this.createdAt,
      updatedAt: DateTime.now(),
      deletedAt: deletedAt,
      draft: draft,
      userId: userId ?? this.userId,
      body: body ?? this.body,
      order: order ?? this.order,
      orderedAt: orderedAt ?? (order != null ? DateTime.now() : this.orderedAt),
      pinned: pinned ?? this.pinned,
      private: private ?? this.private,
      priorityId: priorityId,
      doAt: doAt,
      doneAt: doneAt,
    ));
  }

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), ActivitiesBase());
  bool get doNow {
    return !done && doAt?.isSameOrBefore(DateTime.now()) == true;
  }

  bool get scheduled {
    return doAt?.isAfter(DateTime.now()) == true;
  }

  bool get done => doneAt != null;

  @override
  int compareTo(Activity other) {
    return order.compareTo(other.order);
  }
}
