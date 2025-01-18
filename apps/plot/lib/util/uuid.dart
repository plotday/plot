import 'dart:typed_data';
import 'package:uuid/uuid.dart' as uuid;
import 'package:b/b.dart';

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
