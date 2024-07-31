import 'package:collection/collection.dart';

import 'model.dart';
import 'context.dart';

export 'package:plot/util/order.dart';

class Note extends Model implements Comparable<Note> {
  static const pageSize = 25;
  static final _contextStore = Store<int?, Note>();
  static final _topicStore = Store<int, List<Note>>();
  static final Set<int?> _contextDone = {};
  static final Set<int?> _topicDone = {};

  static List<Note> _filter(List<Note> notes, Context? context) => notes
      .where((note) => context == null || context.isParent(note.context))
      .sorted();

  static Stream<List<Note>> stream(Context? context) =>
      _contextStore.stream().map((notes) => _filter(notes, context));
  static Stream<List<Note>> streamTopic(int topic) =>
      _topicStore.streamValue(topic).map((notes) => notes ?? const []);

  static bool more(Context? context) => !_contextDone.contains(context?.id);
  static bool moreTopic(int topic) => !_topicDone.contains(topic);

  // Fetch the next page of notes and return all notes.
  static Future<List<Note>> fetch(Context? context) async {
    var list = _filter(_contextStore.list(), context);
    if (_contextDone.contains(context?.id)) return list;
    Order? lastOrder;
    if (list.isNotEmpty) {
      lastOrder = list.last.order;
    }
    var query = base.from('note_x').select().eq("root", true);
    if (context != null) {
      query = query.filter('context_path', 'cs', context.path);
    }
    if (lastOrder != null) {
      query = query.gt('order', lastOrder.value);
    }
    final response = await query.order('order').limit(pageSize);
    final models = response.map((r) => Note.fromJson(r)).toList();
    for (final note in models) {
      _insert(note);
    }
    if (models.length < pageSize) {
      _contextDone.add(context?.id);
    }
    return list + models;
  }

  static Future<List<Note>> fetchTopic(int topic) async {
    List<Note> list =
        _topicStore.has(topic) ? _topicStore.get(topic) : const [];
    if (_topicDone.contains(topic)) return list;
    Order? lastOrder;
    if (list.isNotEmpty) {
      lastOrder = list.last.order;
    }
    var query = base.from('note').select().eq("topic_id", topic);
    if (lastOrder != null) {
      query = query.gt('order', lastOrder.value);
    }
    final response = await query
        .order('root', ascending: false)
        .order('order')
        .limit(pageSize);
    final models = response.map((r) => Note.fromJson(r)).toList();
    _appendToTopic(models);
    if (models.length < pageSize) {
      _topicDone.add(topic);
    }
    return list + models;
  }

  Note({
    required Context context,
    required this.body,
    required this.order,
    this.private = false,
    super.id,
  })  : _userId = null,
        topic = null,
        root = true,
        _contextId = context.id!,
        createdAt = DateTime.now(),
        modifiedAt = DateTime.now();

  Note.inTopic({
    required Note parent,
    required this.body,
    required this.order,
    this.private = false,
    super.id,
  })  : _userId = null,
        topic = parent.topic,
        root = false,
        _contextId = parent._contextId,
        createdAt = DateTime.now(),
        modifiedAt = DateTime.now();

  const Note._({
    required this.createdAt,
    required this.modifiedAt,
    required this.topic,
    required int contextId,
    required this.body,
    required this.root,
    required this.order,
    required this.private,
    super.id,
  })  : _userId = null,
        _contextId = contextId;

  @override
  Note.fromJson(Map<String, dynamic> json)
      : createdAt = DateTime.parse(json['created_at'] as String),
        modifiedAt = DateTime.parse(json['modified_at'] as String),
        _userId = json['user_id'] as String,
        _contextId = json['context_id'] as int,
        topic = json['topic_id'] as int,
        body = json['body'] as String,
        root = json['root'] as bool,
        order = Order.fromString(json['order'] as String),
        private = json['private'] as bool,
        super(id: json['id'] as int);

  @override
  int compareTo(Note other) {
    return order.compareTo(other.order);
  }

  bool before(Note other) => compareTo(other) < 0;
  bool after(Note other) => compareTo(other) > 0;

  final DateTime createdAt;
  final DateTime modifiedAt;
  final String? _userId;
  final int _contextId;
  final int? topic;
  final String body;
  final Order order;
  final bool root;
  final bool private;

  Context get context => Context.store.get(_contextId);

  Note copyWith({
    String? body,
    bool? root,
    Order? order,
    bool? private,
  }) {
    return Note._(
      id: id,
      createdAt: createdAt,
      modifiedAt: modifiedAt,
      contextId: _contextId,
      topic: topic,
      body: body ?? this.body,
      root: root ?? this.root,
      order: order ?? this.order,
      private: private ?? this.private,
    );
  }

  @override
  Future<Note> save() async {
    _insert(this);
    final model = await saveToBase("note", Note.fromJson);
    _insert(model);
    return model;
  }

  static void _insert(Note note) {
    if (note.root) {
      _contextStore.put(note.id!, note);
    }
    List<Note> topicNotes = _topicStore.get(note.topic!);
    topicNotes.removeWhere((n) => n.id == note.id);
    final newPos = lowerBound(topicNotes, note);
    topicNotes.insert(newPos, note);
    _topicStore.put(note.topic!, topicNotes);
  }

  static void _appendToTopic(List<Note> notes) {
    if (notes.isEmpty) return;
    if (notes.first.root) {
      _contextStore.put(notes.first.id!, notes.first);
    }
    List<Note> topicNotes = _topicStore.has(notes.first.topic!)
        ? _topicStore.get(notes.first.topic!)
        : const [];
    _topicStore.put(notes.first.topic!, topicNotes + notes);
  }

  @override
  List<Object?> get props =>
      super.props +
      [
        _contextId,
        topic,
        body,
        root,
        order,
        private,
      ];

  @override
  Map<String, dynamic> toJson() => {
        'user_id': _userId ?? base.auth.currentUser?.id,
        'context_id': _contextId,
        'topic_id': topic,
        'body': body,
        'root': root,
        'order': order.value,
        'private': private,
      };
}
