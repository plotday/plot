part of 'store.dart';

@DataClassName('UserSettingsRow')
class UserSettings extends Table with SyncableTable {
  BlobColumn get userId => blob().map(const UuidConverter())();
  TextColumn get enterBehavior =>
      text().nullable().map(const EnumConverter<EnterBehavior>())();
  BoolColumn get aiEnabled => boolean().nullable()();
  BoolColumn get onboardingCompleted => boolean().nullable()();

  /// Stable keys of the curated focus suggestions the user has created a focus
  /// from. Hides those suggestions in the "Add a focus" picker. Synced; the
  /// server union-merges so dismissals are monotonic across devices.
  TextColumn get dismissedFocusSuggestions =>
      text().nullable().map(const StringListConverter())();

  /// When non-null, the user has paused time tracking since this instant.
  /// Drives the client tracker (skip [Session.resume] while paused) and
  /// the server event finalizer (skip occurrences inside the paused window).
  DateTimeColumn get trackingPausedAt =>
      dateTime().nullable().map(const LocalDateTimeConverter())();

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
    // Matches the guard in [watch] — start() callers from the UserReady
    // listener can race with a forced sign-out that has already nulled
    // `_userId`.
    final userId = Base.userIdOrNull;
    if (userId == null) return null;
    final result =
        await (table.select()
              ..where((tbl) => tbl.userId.equals(userId.toBytes())))
            .getSingleOrNull();
    return result;
  }

  static Stream<UserSettingsRow?> watch() {
    // NowBloc.start() runs this from the UserReady listener, which can race
    // with a forced sign-out that has already nulled `_userId`. Match the
    // guard in `Priority._watchActivePriorityIds` and emit a single null
    // rather than crashing on `Base.userId!`.
    final userId = Base.userIdOrNull;
    if (userId == null) return Stream<UserSettingsRow?>.value(null);
    return (table.select()
          ..where((tbl) => tbl.userId.equals(userId.toBytes())))
        .watchSingleOrNull();
  }

  static Future<void> save(UserSettingsCompanion data) async {
    // Matches the guard in [get] / [watch] — onboarding and settings callers
    // can race with a forced sign-out that has already nulled `_userId`.
    final userId = Base.userIdOrNull;
    if (userId == null) return;
    await Store.get.save(
      table,
      data.copyWith(userId: Value(userId)),
      UserSettingsBase(),
    );
  }
}
