import 'package:uuid/uuid.dart';

typedef UUID = UuidValue;

UUID generateUUID() => const Uuid().v4obj();
UUID parseUUID(String uuid) => UuidValue.fromString(uuid);
