import 'package:meta/meta.dart';
import 'package:equatable/equatable.dart';
import 'package:plot/base.dart';
import 'package:plot/util/uuid.dart';

export 'package:plot/base.dart';
export 'package:plot/util/uuid.dart';

abstract class Model extends Equatable {
  const Model();

  Object? get id;

  Future<Model> save();

  @override
  List<Object?> get props => [id];

  Map<String, dynamic> toJson() => {
        'user_id': base.auth.currentUser?.id,
      };
}

abstract class RemoteModel<ID> extends Model {
  @protected
  static Future<List<T>> saveListToBase<ID, T extends RemoteModel<ID>>(
    List<T> items,
    String table,
    T Function(Map<String, dynamic> json) ctor,
  ) async {
    try {
      final newItems = items.where((item) => item.id == null).toList();
      final updatedItems = items.where((item) => item.id != null).toList();
      List<Map<String, dynamic>> dbItems = [];
      if (newItems.isNotEmpty) {
        dbItems = await base
            .from(table)
            .insert(newItems
                .map((item) => {
                      'user_id': base.auth.currentUser?.id,
                      ...item.toJson(),
                    })
                .toList())
            .select();
      }
      if (updatedItems.isNotEmpty) {
        dbItems = dbItems +
            await Future.wait(updatedItems.map((item) => base
                .from(table)
                .update({
                  'user_id': base.auth.currentUser?.id,
                  ...item.toJson(),
                })
                .eq('id', item.id!)
                .select()
                .single()));
      }
      return dbItems.map((json) => ctor(json)).toList();
    } catch (e) {
      print("Error saving $items");
      print(e);
      rethrow;
    }
  }

  const RemoteModel({
    this.id,
  });

  @protected
  Future<T> saveToBase<T extends RemoteModel<ID>>(
    String table,
    T Function(Map<String, dynamic> json) ctor,
  ) async =>
      (await saveListToBase<ID, T>([this as T], table, ctor)).first;

  RemoteModel.fromJson(Map<String, dynamic> json) : id = json['id'] as ID;

  @override
  final ID? id;
}

abstract class LocalModel extends Model {
  LocalModel() : id = generateUUID();

  const LocalModel.withId(this.id);

  LocalModel.fromJson(Map<String, dynamic> json)
      : id = parseUUID(json['id'] as String);

  @override
  final UUID id;

  @protected
  Future<T> saveToBase<T extends Model>(
    String table,
    T Function(Map<String, dynamic> json) ctor,
  ) async {
    try {
      Map<String, dynamic> dbItem =
          await base.from(table).upsert(toJson()).select().single();
      return ctor(dbItem);
    } catch (e) {
      print("Error saving $this");
      print(e);
      rethrow;
    }
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id.toString(),
        ...super.toJson(),
      };
}
