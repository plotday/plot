import 'package:equatable/equatable.dart';
import 'package:plot/util/uuid.dart';

export 'package:plot/base.dart';
export 'package:plot/util/uuid.dart';

abstract class Model extends Equatable {
  const Model({required this.createdAt, required this.modifiedAt});

  Object get id;
  final DateTime createdAt;
  final DateTime modifiedAt;

  Future<void> save();

  @override
  List<Object?> get props => [id];
}

// Models that are always created (and assigned their ID) remotely.
abstract class RemoteModel<ID extends Object> extends Model {
  const RemoteModel({
    required this.id,
    required super.createdAt,
    required super.modifiedAt,
  });

  @override
  final ID id;
}

// Models that are created and assigned UUIDs locally.
abstract class LocalModel extends Model {
  const LocalModel({
    required this.id,
    required super.createdAt,
    required super.modifiedAt,
  });

  LocalModel.create()
      : id = generateUuid(),
        super(
          createdAt: DateTime.now(),
          modifiedAt: DateTime.now(),
        );

  @override
  final Uuid id;
}
