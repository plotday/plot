part of 'store.dart';

typedef ContextId = Uuid;
typedef TopicId = Uuid;

@DataClassName('ContextRow')
class Contexts extends UuidStoreTable {
  TextColumn get name => text()();
  TextColumn get path => text().map(const PathConverter())();
  RealColumn get order => real()
      .clientDefault(() => Order.last().value)
      .map(const OrderConverter())();
  IntColumn get pomodoro => integer()
      .withDefault(const Constant(25 * 60))
      .map(const DurationConverter())();
}

class ContextsBase extends BaseTable {
  ContextsBase() : super(table: 'context_x', name: "contexts");

  @override
  Insertable<ContextRow> fromBase(Map<String, dynamic> json) =>
      ContextRow.fromJson(json);
}

class Context extends ContextRow implements Comparable<Context> {
  static TableInfo<Contexts, ContextRow> get table => Store.get.contexts;

  static Future<void> push() => Store.get.push(table, ContextsBase());
  static Future<bool> pull() => Store.get.pull(table, ContextsBase());

  static Stream<Map<Uuid, Context>> watch() {
    final query = Store.get.select(table);
    return query.watch().map((rows) {
      final contexts = <Uuid, Context>{};
      for (var row in rows) {
        final context = Context.fromStore(row);
        contexts[context.id] = context;
      }
      return contexts;
    });
  }

  static Stream<List<Context>> watchChildren({Path? path}) {
    final query = Store.get.select(table);
    if (path != null) {
      query.where((t) => t.path.like("${path.root}%"));
    }
    // order by path so parents always precede children
    query.orderBy([(t) => OrderingTerm(expression: t.path)]);

    return query.watch().map((rows) {
      List<Context> children = [];
      List<({Context parent, List<Context> children})> stack = [];

      void popStack(int depth) {
        for (var i = stack.length - 1; i >= max(1, depth); i--) {
          stack[i].children.sort();
          stack[i].parent.setChildren(stack[i].children);
        }
        stack.removeRange(depth, stack.length);
      }

      for (var row in rows) {
        final context =
            Context.fromStore(row, parent: stack.firstOrNull?.parent);
        if (path == null && context.path.isRoot) {
          children.add(context);
        } else if (context.path == path) {
          children = [context];
        }
        if (stack.isNotEmpty && stack.last.parent.path == context.path.parent) {
          stack.last.children.add(context);
        } else if (stack.isNotEmpty &&
            !stack.last.parent.path.isParent(context.path)) {
          popStack(context.path.depth);
        }
        stack.add((parent: context, children: []));
      }
      popStack(0);
      children.sort();
      return children;
    });
  }

  Context({
    required super.name,
    required super.order,
    this.parent,
    super.pomodoro = const Duration(minutes: 25),
  })  : children = [],
        super(
          id: Uuid.generate(),
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
          path: Path.generate(parent: parent?.path),
        );

  Context.fromStore(ContextRow row, {this.parent})
      : children = [],
        super(
          id: row.id,
          createdAt: row.createdAt,
          modifiedAt: row.modifiedAt,
          name: row.name,
          pomodoro: row.pomodoro,
          order: row.order,
          path: row.path,
        );

  final Context? parent;
  final List<Context> children;

  Future<void> save() => Store.get.save(table, this);

  void setChildren(List<Context> children) {
    children
      ..clear()
      ..addAll(children)
      ..sort();
  }

  @override
  int compareTo(Context other) {
    return order.compareTo(other.order);
  }
}
