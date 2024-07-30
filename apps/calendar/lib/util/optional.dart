import 'dart:collection';

class Optional<T> extends IterableBase<T> {
  /// Constructs an empty Optional.
  const Optional.absent()
      : _value = null,
        _absent = true;

  /// Constructs an Optional of the given [value].
  Optional.of(T? value)
      : _value = value,
        _absent = false;

  final T? _value;
  final bool _absent;

  /// True when this optional contains a value.
  bool get isPresent => !_absent;

  /// True when this optional contains no value.
  bool get isNotPresent => _absent;

  /// True when this optional contains a non-null value.
  bool get isNotNull => !_absent && _value != null;

  /// Gets the Optional value.
  ///
  /// Throws [StateError] if [value] is absent.
  T? get value {
    if (_absent) {
      throw StateError('value called on absent Optional.');
    }
    return _value;
  }

  /// Gets the Optional value with a default.
  ///
  /// The default is returned if the Optional is [absent()].
  T? or(T? defaultValue) {
    return _absent ? defaultValue : _value;
  }

  /// Gets the Optional value, or `null` if there is none.
  T? get orNull => _absent ? null : _value;

  @override
  Iterator<T> get iterator =>
      _value == null ? Iterable<T>.empty().iterator : <T>[_value].iterator;

  /// Delegates to the underlying [value] hashCode.
  @override
  int get hashCode => _value.hashCode;

  /// Delegates to the underlying [value] operator==.
  @override
  bool operator ==(Object o) => o is Optional<T> && o._value == _value;

  @override
  String toString() {
    return _value == null
        ? 'Optional { absent }'
        : 'Optional { value: $_value }';
  }
}
