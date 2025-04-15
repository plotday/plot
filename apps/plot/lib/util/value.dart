import 'package:drift/drift.dart' show Value;
export 'package:drift/drift.dart' show Value;

extension ValueExtension<T> on Value<T> {
  bool get notNull => present && value != null;
  T? or(T? fallback) => present ? value : fallback;
  T? get orNull => present ? value : null;
  Value<T> operator |(Value<T> other) => present ? this : other;
}
