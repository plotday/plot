part of 'store.dart';

typedef ActivityId = Uuid;

@DataClassName('ActivityRow')
class Activities extends UuidStoreTable with DraftTable, DeletableTable {
  BlobColumn get userId =>
      blob()
          .clientDefault(() => Uuid.generate().toBytes())
          .map(const UuidConverter())();
  TextColumn get body => text()();
  RealColumn get order =>
      real()
          .clientDefault(() => Order.first().value)
          .map(const OrderConverter())();
  DateTimeColumn get orderedAt =>
      dateTime()
          .withDefault(currentDateAndTime)
          .map(const LocalDateTimeConverter())();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get private => boolean().withDefault(const Constant(false))();
  BlobColumn get priorityId =>
      blob().map(const UuidConverter()).references(Priorities, #id)();
  DateTimeColumn get doAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
  DateTimeColumn get doneAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();
}

class ActivitiesBase extends BaseTable {
  ActivitiesBase({super.limit, super.filterName})
    : super(
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
  PriorityActivitiesBase({this.priorityId, this.priorityPath})
    : super(filterName: priorityPath?.toString(), limit: 40);

  final PriorityId? priorityId;
  final Path? priorityPath;

  @override
  PostgrestFilterBuilder<T> filter<T>(PostgrestFilterBuilder<T> query) {
    if (priorityPath != null) {
      query = query.filter('priority_path', 'cs', priorityPath);
    }
    return query;
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
  static Future<bool> pullPriority(
    PriorityId priorityId, {
    bool more = false,
  }) async => Store.get.pull(
    more ? PullType.more : PullType.initial,
    table,
    PriorityActivitiesBase(priorityId: priorityId),
  );
  static Future<bool> pullPriorityPath(
    Path? priorityPath, {
    bool more = false,
  }) async => Store.get.pull(
    more ? PullType.more : PullType.initial,
    table,
    PriorityActivitiesBase(priorityPath: priorityPath),
  );
  static Future<bool> pullActive(DateTime until) async =>
      Store.get.pull(PullType.all, table, ActiveActivitiesBase(until));
  static bool hasMorePriority(Path? priorityPath) =>
      Store.get.hasMore(PriorityActivitiesBase(priorityPath: priorityPath));

  static Future<Activity> get(ActivityId id) async {
    return await (Store.get.select(table)..where(
      (t) => t.id.equals(id.toBytes()),
    )).getSingle().then(Activity.fromStore);
  }

  static Future<Activity?> getDraft({PriorityId? priorityId}) async {
    if (priorityId != null) {
      pullPriority(priorityId);
    }
    final query = Store.get.select(table)..where((t) => t.draft.equals(true));
    if (priorityId != null) {
      query.where((t) => t.priorityId.equals(priorityId.toBytes()));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    query.limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return Activity.fromStore(row);
  }

  static Stream<Activity> watchOne(ActivityId id) {
    final query = Store.get.select(table);
    query.where((t) => t.id.equals(id.toBytes()));
    return query.watchSingle().map(Activity.fromStore);
  }

  static Stream<List<Activity>> watchPriority(
    PriorityId priorityId, {
    Path? priorityPath,
    bool? deleted = false,
    bool? draft,
    bool? active,
  }) {
    if (priorityPath != null) {
      pullPriorityPath(priorityPath);
    } else {
      pullPriority(priorityId);
    }
    final query = Store.get.select(table).join([
      innerJoin(
        Store.get.priorities,
        Store.get.priorities.id.equalsExp(Store.get.activities.priorityId),
        useColumns: false,
      ),
    ]);

    // If priorityPath is provided, we want to get activities from this priority
    // and all its descendants. Otherwise, just get activities for the specific priorityId.
    if (priorityPath != null) {
      query.where(Store.get.priorities.path.like("$priorityPath%"));
    } else {
      query.where(Store.get.activities.priorityId.equals(priorityId.toBytes()));
    }

    if (deleted != null) {
      query.where(
        deleted
            ? Store.get.activities.deletedAt.isNotNull()
            : Store.get.activities.deletedAt.isNull(),
      );
    }
    if (draft != null) {
      query.where(Store.get.activities.draft.equals(draft));
    }
    if (active != null) {
      final exp =
          Store.get.activities.doAt.isNotNull() &
          Store.get.activities.doAt.isSmallerThanValue(DateTime.now()) &
          Store.get.activities.doneAt.isNull();
      query.where(active ? exp : exp.not());
    }

    query.orderBy([
      OrderingTerm.desc(Store.get.activities.pinned),
      OrderingTerm(
        expression: const CustomExpression<DateTime>(
          'CASE WHEN do_at IS NOT NULL AND done_at IS NULL AND do_at <= CURRENT_TIMESTAMP THEN do_at ELSE NULL END',
        ),
        mode: OrderingMode.asc,
      ),
      OrderingTerm.desc(Store.get.activities.order),
    ]);

    return query.watch().map(
      (rows) =>
          rows
              .map(
                (row) =>
                    Activity.fromStore(row.readTable(Store.get.activities)),
              )
              .toList(),
    );
  }

  // Stream of items that are currently active, and will become active before
  // the end of the current day.
  static Stream<List<Activity>> watchActive({bool? deleted = false}) {
    return Date.current().switchMap((date) {
      pullActive(date.toEnd());
      final query = Store.get.select(table)..where(
        (t) =>
            t.draft.equals(false) &
            t.doAt.isSmallerThanValue(date.toEnd()) &
            t.doneAt.isNull(),
      );
      if (deleted != null) {
        query.where(
          (t) => deleted ? t.deletedAt.isNotNull() : t.deletedAt.isNull(),
        );
      }
      return query.watch().map(
        (rows) => rows.map((row) => Activity.fromStore(row)).toList(),
      );
    });
  }

  factory Activity.draft({
    required PriorityId priorityId,
    bool pinned = false,
    DateTime? doAt,
  }) {
    final id = Uuid.generate();
    final now = DateTime.now();
    return Activity.fromStore(
      ActivityRow(
        id: id,
        priorityId: priorityId,
        userId: Base.userId,
        createdAt: now,
        updatedAt: now,
        draft: true,
        doAt: doAt,
        body: "",
        order: Order.first(),
        orderedAt: now,
        private: true,
        pinned: pinned,
      ),
    );
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

  Activity merge(Activity other) {
    return copyWith(
      body: body.isEmpty ? other.body : body,
      doAt: Value(doAt ?? other.doAt),
      doneAt: Value(doneAt ?? other.doneAt),
      pinned: pinned || other.pinned,
      private: private || other.private,
    );
  }

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
    PriorityId? priorityId,
    Value<DateTime?> doAt = const Value.absent(),
    Value<DateTime?> doneAt = const Value.absent(),
  }) {
    final publish = this.draft && draft == false;
    if (doAt.present && doAt.value != null) {
      doneAt = const Value(null);
      pinned = false;
    } else if (pinned == true) {
      doAt = const Value(null);
      doneAt = const Value(null);
    }
    if (publish ||
        (doAt.present && doAt.value != this.doAt) ||
        (doneAt.present && doneAt.value != this.doneAt) ||
        (pinned != null && pinned != this.pinned)) {
      order ??=
          (doAt.or(this.doAt) != null || (pinned ?? this.pinned) == true)
              ? Order.last()
              : Order.first();
    }
    return Activity.fromStore(
      super.copyWith(
        createdAt: publish ? DateTime.now() : this.createdAt,
        updatedAt: DateTime.now(),
        orderedAt:
            orderedAt ?? (order != null ? DateTime.now() : this.orderedAt),
        deletedAt: deletedAt,
        id: id,
        draft: draft,
        userId: userId,
        body: body,
        order: order,
        pinned: pinned,
        private: private,
        priorityId: priorityId,
        doAt: doAt,
        doneAt: doneAt,
      ),
    );
  }

  Future<void> save() =>
      Store.get.save(table, toCompanion(false), ActivitiesBase());
  bool get doNow {
    return !done && doAt?.isSameOrBefore(DateTime.now()) == true;
  }

  // TODO generate title from body
  String get title => body;

  bool get scheduled {
    return doAt?.isAfter(DateTime.now()) == true;
  }

  bool get done => doneAt != null;

  @override
  int compareTo(Activity other) {
    return order.compareTo(other.order);
  }
}
