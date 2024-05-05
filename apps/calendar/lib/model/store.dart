import 'package:rxdart/subjects.dart';

class Store<ID, T> {
  Store(
      {Future<Iterable<MapEntry<ID, T>>> Function()? load,
      Map<ID, T> values = const {}})
      : _load = load,
        _cache = values,
        _streamController = BehaviorSubject<List<T>>.seeded(const []);

  final Future<Iterable<MapEntry<ID, T>>> Function()? _load;
  Future<void>? _waitForInit;
  Map<ID, T> _cache;
  final BehaviorSubject<List<T>> _streamController;

  List<T> list() => _streamController.value;
  Stream<List<T>> stream() => _streamController.asBroadcastStream();

  Future<void> load() async {
    if (_waitForInit != null) {
      await _waitForInit;
    } else if (_load != null) {
      _waitForInit = _load().then(set);
    }
  }

  void set(Iterable<MapEntry<ID, T>> values) async {
    _cache = Map.fromEntries(values);
    _streamController.add(_cache.values.toList());
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
    _streamController.add(_cache.values.toList());
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
