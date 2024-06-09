import 'package:equatable/equatable.dart';
import 'package:plot/base.dart';

export 'package:plot/base.dart';
export 'store.dart';

abstract class Model extends Equatable {
  static Future<List<T>> saveListToBase<T extends Model>(
    List<T> items,
    String table,
    T Function(Map<String, dynamic> json) ctor,
  ) async {
    return (await base
            .from(table)
            .upsert(items
                .map((item) => {
                      ...item.toJson(),
                      'user_id': base.auth.currentUser?.id,
                    })
                .toList())
            .select())
        .map((json) => ctor(json))
        .toList();
  }

  const Model({
    this.id,
  });

  Future<T> saveToBase<T extends Model>(
    String table,
    T Function(Map<String, dynamic> json) ctor,
  ) async =>
      (await saveListToBase<T>([this as T], table, ctor)).first;

  Model.fromJson(Map<String, dynamic> json) : id = json['id'] as int;

  final int? id;

  Future<Model> save();

  @override
  List<Object?> get props => [id ?? 0];

  Map<String, dynamic> toJson();
}
