import 'package:rxdart/subjects.dart';

class Store<ID, T> {
  Store({
    Future<Iterable<MapEntry<ID, T>>> Function()? load,
    Map<ID, T> values = const {},
  })  : _load = load,
        _cache = Map.of(values),
        _streamController = BehaviorSubject<Map<ID, T>>.seeded(const {});

  final Future<Iterable<MapEntry<ID, T>>> Function()? _load;
  Future<void>? _waitForInit;
  Map<ID, T> _cache;
  final BehaviorSubject<Map<ID, T>> _streamController;

  List<T> list() => _streamController.value.values.toList();
  Stream<List<T>> stream() =>
      _streamController.map((map) => map.values.toList()).asBroadcastStream();
  Stream<T?> streamValue(ID id) {
    return _streamController.map((map) {
      return map[id];
    }).asBroadcastStream();
  }

  Future<void> load() async {
    if (_load == null) return;
    _waitForInit ??= _load().then(set);
    try {
      await _waitForInit;
    } catch (e, stacktrace) {
      print("Error loading $T store");
      print(e);
      print(stacktrace);
      rethrow;
    }
  }

  void set(Iterable<MapEntry<ID, T>> values) async {
    _cache = Map.fromEntries(values);
    _streamController.add(_cache);
  }

  bool has(ID id) {
    return _cache.containsKey(id);
  }

  T get(ID id) {
    if (!_cache.containsKey(id)) {
      throw ArgumentError('$id not found');
    }
    return _cache[id]!;
  }

  void put(ID id, T value) {
    _cache[id] = value;
    _streamController.add(_cache);
  }
}

class SingleStore<T> {
  SingleStore({Future<T> Function()? load})
      : _load = load,
        _streamController = BehaviorSubject();

  final Future<T> Function()? _load;
  Future<void>? _waitForInit;
  final BehaviorSubject<T> _streamController;

  Future<void> load() async {
    if (_waitForInit != null) {
      await _waitForInit;
    } else if (_load != null) {
      _waitForInit = _load().then(set);
    }
  }

  Stream<T> stream() => _streamController.asBroadcastStream();
  T? get() {
    return _streamController.valueOrNull;
  }

  void set(T value) async {
    _streamController.add(value);
  }
}
