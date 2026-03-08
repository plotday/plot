part of 'store.dart';

@DataClassName('UserSettingsRow')
class UserSettings extends Table with SyncableTable {
  BlobColumn get userId => blob().map(const UuidConverter())();
  TextColumn get enterBehavior =>
      text().nullable().map(const EnumConverter<EnterBehavior>())();
  BoolColumn get aiEnabled => boolean().nullable()();

  @override
  Set<Column> get primaryKey => {userId};
}

class UserSettingsBase extends BaseTable {
  UserSettingsBase()
    : super(
        table: 'user_settings',
        syncEndpoint: 'user-settings',
        name: "user_settings",
        order: 'updated_at',
        supportsArchiving: false,
        cursorColumn: 'user_id',
      );

  @override
  Insertable<UserSettingsRow> fromBase(Map<String, dynamic> json) {
    return UserSettingsRow.fromJson(json);
  }

  @override
  Map<String, dynamic> toBase(DataClass row) {
    final json = super.toBase(row);
    json.remove('updated_by');
    return json;
  }
}

class UserSettingsEntity {
  static $UserSettingsTable get table => Store.get.userSettings;

  static Future<bool> push() => Store.get.push(table, UserSettingsBase());

  static Future<void> pull() async {
    await Store.get.pull(table, UserSettingsBase(), initial: true);
    await Store.get.pull(table, UserSettingsBase());
  }

  static Future<UserSettingsRow?> get() async {
    final result =
        await (table.select()
              ..where((tbl) => tbl.userId.equals(Base.userId.toBytes())))
            .getSingleOrNull();
    return result;
  }

  static Stream<UserSettingsRow?> watch() {
    return (table.select()
          ..where((tbl) => tbl.userId.equals(Base.userId.toBytes())))
        .watchSingleOrNull();
  }

  static Future<void> save(UserSettingsCompanion data) async {
    final userId = Base.userId;
    await Store.get.save(
      table,
      data.copyWith(userId: Value(userId)),
      UserSettingsBase(),
    );
  }
}
