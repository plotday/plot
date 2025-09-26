import 'package:uuid/uuid.dart' as uuid;
import 'package:b/b.dart';
import 'package:drift/drift.dart';

extension type Uuid(uuid.UuidValue value) {
  factory Uuid.generate() => Uuid(const uuid.Uuid().v7obj());

  factory Uuid.fromString(String value) =>
      Uuid(uuid.UuidValue.fromString(value));
  factory Uuid.fromShortString(String value) {
    final withoutDashes = BaseConversion(from: base58, to: base16)(value)
        .padLeft(32, '0')
        .toLowerCase();
    final withDashes = '${withoutDashes.substring(0, 8)}-'
        '${withoutDashes.substring(8, 12)}-'
        '${withoutDashes.substring(12, 16)}-'
        '${withoutDashes.substring(16, 20)}-'
        '${withoutDashes.substring(20)}';
    return Uuid.fromString(withDashes);
  }
  factory Uuid.fromBytes(Uint8List byteList) =>
      Uuid(uuid.UuidValue.fromByteList(byteList));

  Uint8List toBytes() => value.toBytes();
  String toShortString() {
    return BaseConversion(from: base16, to: base58)(
        value.toString().replaceAll('-', '').toUpperCase());
  }
}

class UuidConverter extends TypeConverter<Uuid, Uint8List>
    with JsonTypeConverter2<Uuid, Uint8List, String> {
  const UuidConverter();

  @override
  Uuid fromSql(Uint8List fromDb) {
    return Uuid.fromBytes(fromDb);
  }

  @override
  Uint8List toSql(Uuid value) {
    return value.toBytes();
  }

  @override
  Uuid fromJson(String json) {
    return Uuid.fromString(json);
  }

  @override
  String toJson(Uuid value) {
    return value.toString();
  }
}
