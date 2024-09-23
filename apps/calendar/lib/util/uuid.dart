import 'dart:typed_data';
import 'package:uuid/uuid.dart' as uuid;

extension type Uuid(uuid.UuidValue value) {
  factory Uuid.generate() => Uuid(const uuid.Uuid().v7obj());
  factory Uuid.nil() => Uuid(uuid.Namespace.nil.uuidValue);

  factory Uuid.fromString(String value) =>
      Uuid(uuid.UuidValue.fromString(value));
  factory Uuid.fromBytes(Uint8List byteList) =>
      Uuid(uuid.UuidValue.fromByteList(byteList));

  Uint8List toBytes() => value.toBytes();
}
