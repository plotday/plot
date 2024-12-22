part of 'store.dart';

typedef ActivityId = Uuid;
typedef TopicId = Uuid;

@DataClassName('ActivityRow')
class Activities extends UuidStoreTable with DraftTable {
  TextColumn get name => text()();
  TextColumn get path => text().map(const PathConverter())();
  RealColumn get order => real()
      .clientDefault(() => Order.last().value)
      .map(const OrderConverter())();
  IntColumn get pomodoro => integer()
      .withDefault(const Constant(25 * 60))
      .map(const DurationConverter())();
  IntColumn get color => integer()
      .withDefault(const Constant(0))
      .map(const ThemeColorConverter())();
}

class ActivitiesBase extends BaseTable {
  ActivitiesBase()
      : super(table: 'activity_x', name: "activities", upsertAsUpdate: true);

  @override
  Insertable<ActivityRow> fromBase(Map<String, dynamic> json) =>
      ActivityRow.fromJson(json);
}

class Activity extends ActivityRow implements Comparable<Activity> {
  static $ActivitiesTable get table => Store.get.activities;
  static CustomExpression<
      bool> pathDepth(Path? path, int depth) => CustomExpression<
          bool>(
      "LENGTH(path) - LENGTH(REPLACE(path, '.', '')) <= ${path == null ? depth - 1 : path.depth + depth}");

  static Future<void> push() => Store.get.push(table, ActivitiesBase());
  static Future<bool> pull() =>
      Store.get.pull(PullType.all, table, ActivitiesBase());

  static Future<Activity> get(ActivityId id) async {
    return await (Store.get.select(table)
          ..where((t) => t.id.equals(id.toBytes())))
        .getSingle()
        .then((row) {
      return Activity.fromStore(row);
    });
  }

  static Stream<Map<Uuid, Activity>> watch() {
    return watchAll().map((rows) {
      final activities = <Uuid, Activity>{};
      void add(Activity activity) {
        activities[activity.id] = activity;
        for (var child in activity.children) {
          add(child);
        }
      }

      for (var row in rows) {
        add(row);
      }
      return activities;
    });
  }

  static Stream<Activity> watchOne(ActivityId id, {int depth = 0}) {
    final query = Store.get.select(table);
    query.where((t) => t.id.equals(id.toBytes()));
    return query.watchSingle().asyncExpand((row) {
      return watchPath(row.path, depth: depth)
          .map((contexts) => contexts.first);
    });
  }

  static Stream<List<Activity>> watchAll() => watchPath(null, depth: null);

  static Stream<List<Activity>> watchRoot({int? depth = 1}) =>
      watchPath(null, depth: depth);

  static Stream<List<Activity>> watchPath(Path? path, {int? depth = 1}) {
    final query = Store.get.select(table);
    if (path != null) {
      query.where((t) =>
          Variable<String>(path.toString())
              .likeExp(t.path + const Constant('%')) |
          t.path.like("$path.%"));
    }
    if (depth != null) {
      query.where((t) => pathDepth(path, (path?.depth ?? 0) + depth));
    }
    // order by path so parents always precede children
    query.orderBy([(t) => OrderingTerm(expression: t.path)]);

    return query.watch().map((rows) {
      List<Activity> matches = [];
      List<Activity> stack = [];

      for (var row in rows) {
        var activity = Activity.fromStore(row);

        if (stack.isNotEmpty && !stack.last.path.isParent(activity.path)) {
          stack.removeWhere((c) => !c.path.isParent(activity.path));
        }

        if (stack.isNotEmpty) {
          activity = activity.copyWith(parent: stack.last);
        }

        if ((path == null && activity.path.isRoot) || activity.path == path) {
          matches.add(activity);
          stack.clear();
        }

        stack.add(activity);
      }

      matches.sort();
      return matches;
    });
  }

  Activity({
    required super.name,
    required super.order,
    this.parent,
    super.pomodoro = const Duration(minutes: 25),
    super.color = const ThemeColor.defaultColor(),
  })  : children = [],
        super(
          id: Uuid.generate(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          draft: false,
          path: Path.generate(parent: parent?.path),
        ) {
    parent?._addChild(this);
  }

  Activity.fromStore(ActivityRow row, {this.parent, List<Activity>? children})
      : children = children ?? [],
        super(
          id: row.id,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
          draft: row.draft,
          name: row.name,
          pomodoro: row.pomodoro,
          color: row.color,
          order: row.order,
          path: row.path,
        ) {
    parent?._addChild(this);
  }

  final Activity? parent;
  List<Activity> children;

  @override
  Activity copyWith({
    Uuid? id,
    DateTime? updatedAt,
    DateTime? createdAt,
    bool? draft,
    String? name,
    Path? path,
    Order? order,
    Duration? pomodoro,
    ThemeColor? color,
    Activity? parent,
  }) =>
      Activity.fromStore(
        super.copyWith(
          id: id,
          createdAt:
              this.draft && draft == false ? DateTime.now() : this.createdAt,
          updatedAt: DateTime.now(),
          draft: draft,
          name: name,
          path: path,
          order: order,
          pomodoro: pomodoro,
          color: color,
        ),
        parent: parent ?? this.parent,
        children: children,
      );

  void _addChild(Activity child) {
    children = List<Activity>.from(children)
        .replaceSorted(child, (a, b) => a.id == b.id);
  }

  bool isParent(Activity other) => path.isParent(other.path);
  List<Activity> get ancestry =>
      parent == null ? [this] : parent!.ancestry + [this];

  Future<void> save() => Store.get.save(table, this, ActivitiesBase());

  @override
  int compareTo(Activity other) {
    return order.compareTo(other.order);
  }
}
