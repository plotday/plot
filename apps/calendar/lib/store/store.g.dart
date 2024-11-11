// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'store.dart';

// ignore_for_file: type=lint
class $SyncStatesTable extends SyncStates
    with TableInfo<$SyncStatesTable, SyncState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityMeta = const VerificationMeta('entity');
  @override
  late final GeneratedColumn<String> entity = GeneratedColumn<String>(
      'entity', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pushedAtMeta =
      const VerificationMeta('pushedAt');
  @override
  late final GeneratedColumn<DateTime> pushedAt = GeneratedColumn<DateTime>(
      'pushed_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _lastPulledMeta =
      const VerificationMeta('lastPulled');
  @override
  late final GeneratedColumn<String> lastPulled = GeneratedColumn<String>(
      'last_pulled', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _moreMeta = const VerificationMeta('more');
  @override
  late final GeneratedColumn<bool> more = GeneratedColumn<bool>(
      'more', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("more" IN (0, 1))'),
      defaultValue: const Constant(true));
  @override
  List<GeneratedColumn> get $columns => [entity, pushedAt, lastPulled, more];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_states';
  @override
  VerificationContext validateIntegrity(Insertable<SyncState> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity')) {
      context.handle(_entityMeta,
          entity.isAcceptableOrUnknown(data['entity']!, _entityMeta));
    } else if (isInserting) {
      context.missing(_entityMeta);
    }
    if (data.containsKey('pushed_at')) {
      context.handle(_pushedAtMeta,
          pushedAt.isAcceptableOrUnknown(data['pushed_at']!, _pushedAtMeta));
    }
    if (data.containsKey('last_pulled')) {
      context.handle(
          _lastPulledMeta,
          lastPulled.isAcceptableOrUnknown(
              data['last_pulled']!, _lastPulledMeta));
    }
    if (data.containsKey('more')) {
      context.handle(
          _moreMeta, more.isAcceptableOrUnknown(data['more']!, _moreMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entity};
  @override
  SyncState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncState(
      entity: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}entity'])!,
      pushedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}pushed_at']),
      lastPulled: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_pulled']),
      more: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}more'])!,
    );
  }

  @override
  $SyncStatesTable createAlias(String alias) {
    return $SyncStatesTable(attachedDatabase, alias);
  }
}

class SyncState extends DataClass implements Insertable<SyncState> {
  final String entity;
  final DateTime? pushedAt;
  final String? lastPulled;
  final bool more;
  const SyncState(
      {required this.entity,
      this.pushedAt,
      this.lastPulled,
      required this.more});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity'] = Variable<String>(entity);
    if (!nullToAbsent || pushedAt != null) {
      map['pushed_at'] = Variable<DateTime>(pushedAt);
    }
    if (!nullToAbsent || lastPulled != null) {
      map['last_pulled'] = Variable<String>(lastPulled);
    }
    map['more'] = Variable<bool>(more);
    return map;
  }

  SyncStatesCompanion toCompanion(bool nullToAbsent) {
    return SyncStatesCompanion(
      entity: Value(entity),
      pushedAt: pushedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(pushedAt),
      lastPulled: lastPulled == null && nullToAbsent
          ? const Value.absent()
          : Value(lastPulled),
      more: Value(more),
    );
  }

  factory SyncState.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncState(
      entity: serializer.fromJson<String>(json['entity']),
      pushedAt: serializer.fromJson<DateTime?>(json['pushed_at']),
      lastPulled: serializer.fromJson<String?>(json['last_pulled']),
      more: serializer.fromJson<bool>(json['more']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entity': serializer.toJson<String>(entity),
      'pushed_at': serializer.toJson<DateTime?>(pushedAt),
      'last_pulled': serializer.toJson<String?>(lastPulled),
      'more': serializer.toJson<bool>(more),
    };
  }

  SyncState copyWith(
          {String? entity,
          Value<DateTime?> pushedAt = const Value.absent(),
          Value<String?> lastPulled = const Value.absent(),
          bool? more}) =>
      SyncState(
        entity: entity ?? this.entity,
        pushedAt: pushedAt.present ? pushedAt.value : this.pushedAt,
        lastPulled: lastPulled.present ? lastPulled.value : this.lastPulled,
        more: more ?? this.more,
      );
  SyncState copyWithCompanion(SyncStatesCompanion data) {
    return SyncState(
      entity: data.entity.present ? data.entity.value : this.entity,
      pushedAt: data.pushedAt.present ? data.pushedAt.value : this.pushedAt,
      lastPulled:
          data.lastPulled.present ? data.lastPulled.value : this.lastPulled,
      more: data.more.present ? data.more.value : this.more,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncState(')
          ..write('entity: $entity, ')
          ..write('pushedAt: $pushedAt, ')
          ..write('lastPulled: $lastPulled, ')
          ..write('more: $more')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(entity, pushedAt, lastPulled, more);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncState &&
          other.entity == this.entity &&
          other.pushedAt == this.pushedAt &&
          other.lastPulled == this.lastPulled &&
          other.more == this.more);
}

class SyncStatesCompanion extends UpdateCompanion<SyncState> {
  final Value<String> entity;
  final Value<DateTime?> pushedAt;
  final Value<String?> lastPulled;
  final Value<bool> more;
  final Value<int> rowid;
  const SyncStatesCompanion({
    this.entity = const Value.absent(),
    this.pushedAt = const Value.absent(),
    this.lastPulled = const Value.absent(),
    this.more = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStatesCompanion.insert({
    required String entity,
    this.pushedAt = const Value.absent(),
    this.lastPulled = const Value.absent(),
    this.more = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : entity = Value(entity);
  static Insertable<SyncState> custom({
    Expression<String>? entity,
    Expression<DateTime>? pushedAt,
    Expression<String>? lastPulled,
    Expression<bool>? more,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entity != null) 'entity': entity,
      if (pushedAt != null) 'pushed_at': pushedAt,
      if (lastPulled != null) 'last_pulled': lastPulled,
      if (more != null) 'more': more,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStatesCompanion copyWith(
      {Value<String>? entity,
      Value<DateTime?>? pushedAt,
      Value<String?>? lastPulled,
      Value<bool>? more,
      Value<int>? rowid}) {
    return SyncStatesCompanion(
      entity: entity ?? this.entity,
      pushedAt: pushedAt ?? this.pushedAt,
      lastPulled: lastPulled ?? this.lastPulled,
      more: more ?? this.more,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entity.present) {
      map['entity'] = Variable<String>(entity.value);
    }
    if (pushedAt.present) {
      map['pushed_at'] = Variable<DateTime>(pushedAt.value);
    }
    if (lastPulled.present) {
      map['last_pulled'] = Variable<String>(lastPulled.value);
    }
    if (more.present) {
      map['more'] = Variable<bool>(more.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStatesCompanion(')
          ..write('entity: $entity, ')
          ..write('pushedAt: $pushedAt, ')
          ..write('lastPulled: $lastPulled, ')
          ..write('more: $more, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AccountsTable extends Accounts
    with TableInfo<$AccountsTable, AccountRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AccountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
      'email', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _providerMeta =
      const VerificationMeta('provider');
  @override
  late final GeneratedColumnWithTypeConverter<AccountProvider, String>
      provider = GeneratedColumn<String>('provider', aliasedName, false,
              type: DriftSqlType.string, requiredDuringInsert: true)
          .withConverter<AccountProvider>($AccountsTable.$converterprovider);
  @override
  List<GeneratedColumn> get $columns => [id, modifiedAt, email, provider];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'accounts';
  @override
  VerificationContext validateIntegrity(Insertable<AccountRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    if (data.containsKey('email')) {
      context.handle(
          _emailMeta, email.isAcceptableOrUnknown(data['email']!, _emailMeta));
    } else if (isInserting) {
      context.missing(_emailMeta);
    }
    context.handle(_providerMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AccountRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AccountRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      email: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}email'])!,
      provider: $AccountsTable.$converterprovider.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}provider'])!),
    );
  }

  @override
  $AccountsTable createAlias(String alias) {
    return $AccountsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<AccountProvider, String, String>
      $converterprovider =
      const EnumNameConverter<AccountProvider>(AccountProvider.values);
}

class AccountRow extends DataClass implements Insertable<AccountRow> {
  final int id;
  final DateTime modifiedAt;
  final String email;
  final AccountProvider provider;
  const AccountRow(
      {required this.id,
      required this.modifiedAt,
      required this.email,
      required this.provider});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['email'] = Variable<String>(email);
    {
      map['provider'] =
          Variable<String>($AccountsTable.$converterprovider.toSql(provider));
    }
    return map;
  }

  AccountsCompanion toCompanion(bool nullToAbsent) {
    return AccountsCompanion(
      id: Value(id),
      modifiedAt: Value(modifiedAt),
      email: Value(email),
      provider: Value(provider),
    );
  }

  factory AccountRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AccountRow(
      id: serializer.fromJson<int>(json['id']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      email: serializer.fromJson<String>(json['email']),
      provider: $AccountsTable.$converterprovider
          .fromJson(serializer.fromJson<String>(json['provider'])),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'email': serializer.toJson<String>(email),
      'provider': serializer
          .toJson<String>($AccountsTable.$converterprovider.toJson(provider)),
    };
  }

  AccountRow copyWith(
          {int? id,
          DateTime? modifiedAt,
          String? email,
          AccountProvider? provider}) =>
      AccountRow(
        id: id ?? this.id,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        email: email ?? this.email,
        provider: provider ?? this.provider,
      );
  AccountRow copyWithCompanion(AccountsCompanion data) {
    return AccountRow(
      id: data.id.present ? data.id.value : this.id,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      email: data.email.present ? data.email.value : this.email,
      provider: data.provider.present ? data.provider.value : this.provider,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AccountRow(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('email: $email, ')
          ..write('provider: $provider')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, modifiedAt, email, provider);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccountRow &&
          other.id == this.id &&
          other.modifiedAt == this.modifiedAt &&
          other.email == this.email &&
          other.provider == this.provider);
}

class AccountsCompanion extends UpdateCompanion<AccountRow> {
  final Value<int> id;
  final Value<DateTime> modifiedAt;
  final Value<String> email;
  final Value<AccountProvider> provider;
  const AccountsCompanion({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.email = const Value.absent(),
    this.provider = const Value.absent(),
  });
  AccountsCompanion.insert({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    required String email,
    required AccountProvider provider,
  })  : email = Value(email),
        provider = Value(provider);
  static Insertable<AccountRow> custom({
    Expression<int>? id,
    Expression<DateTime>? modifiedAt,
    Expression<String>? email,
    Expression<String>? provider,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (email != null) 'email': email,
      if (provider != null) 'provider': provider,
    });
  }

  AccountsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? modifiedAt,
      Value<String>? email,
      Value<AccountProvider>? provider}) {
    return AccountsCompanion(
      id: id ?? this.id,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      email: email ?? this.email,
      provider: provider ?? this.provider,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (email.present) {
      map['email'] = Variable<String>(email.value);
    }
    if (provider.present) {
      map['provider'] = Variable<String>(
          $AccountsTable.$converterprovider.toSql(provider.value));
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AccountsCompanion(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('email: $email, ')
          ..write('provider: $provider')
          ..write(')'))
        .toString();
  }
}

class $CalendarsTable extends Calendars
    with TableInfo<$CalendarsTable, CalendarRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _enabledMeta =
      const VerificationMeta('enabled');
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
      'enabled', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("enabled" IN (0, 1))'));
  static const VerificationMeta _accountIdMeta =
      const VerificationMeta('accountId');
  @override
  late final GeneratedColumn<int> accountId = GeneratedColumn<int>(
      'account_id', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES accounts (id)'));
  @override
  List<GeneratedColumn> get $columns =>
      [id, modifiedAt, name, enabled, accountId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendars';
  @override
  VerificationContext validateIntegrity(Insertable<CalendarRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(_enabledMeta,
          enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta));
    } else if (isInserting) {
      context.missing(_enabledMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(_accountIdMeta,
          accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta));
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CalendarRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      enabled: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}enabled'])!,
      accountId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}account_id'])!,
    );
  }

  @override
  $CalendarsTable createAlias(String alias) {
    return $CalendarsTable(attachedDatabase, alias);
  }
}

class CalendarRow extends DataClass implements Insertable<CalendarRow> {
  final int id;
  final DateTime modifiedAt;
  final String name;
  final bool enabled;
  final int accountId;
  const CalendarRow(
      {required this.id,
      required this.modifiedAt,
      required this.name,
      required this.enabled,
      required this.accountId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['name'] = Variable<String>(name);
    map['enabled'] = Variable<bool>(enabled);
    map['account_id'] = Variable<int>(accountId);
    return map;
  }

  CalendarsCompanion toCompanion(bool nullToAbsent) {
    return CalendarsCompanion(
      id: Value(id),
      modifiedAt: Value(modifiedAt),
      name: Value(name),
      enabled: Value(enabled),
      accountId: Value(accountId),
    );
  }

  factory CalendarRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarRow(
      id: serializer.fromJson<int>(json['id']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      name: serializer.fromJson<String>(json['name']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      accountId: serializer.fromJson<int>(json['account_id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'name': serializer.toJson<String>(name),
      'enabled': serializer.toJson<bool>(enabled),
      'account_id': serializer.toJson<int>(accountId),
    };
  }

  CalendarRow copyWith(
          {int? id,
          DateTime? modifiedAt,
          String? name,
          bool? enabled,
          int? accountId}) =>
      CalendarRow(
        id: id ?? this.id,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        accountId: accountId ?? this.accountId,
      );
  CalendarRow copyWithCompanion(CalendarsCompanion data) {
    return CalendarRow(
      id: data.id.present ? data.id.value : this.id,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      name: data.name.present ? data.name.value : this.name,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarRow(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('enabled: $enabled, ')
          ..write('accountId: $accountId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, modifiedAt, name, enabled, accountId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarRow &&
          other.id == this.id &&
          other.modifiedAt == this.modifiedAt &&
          other.name == this.name &&
          other.enabled == this.enabled &&
          other.accountId == this.accountId);
}

class CalendarsCompanion extends UpdateCompanion<CalendarRow> {
  final Value<int> id;
  final Value<DateTime> modifiedAt;
  final Value<String> name;
  final Value<bool> enabled;
  final Value<int> accountId;
  const CalendarsCompanion({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.name = const Value.absent(),
    this.enabled = const Value.absent(),
    this.accountId = const Value.absent(),
  });
  CalendarsCompanion.insert({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    required String name,
    required bool enabled,
    required int accountId,
  })  : name = Value(name),
        enabled = Value(enabled),
        accountId = Value(accountId);
  static Insertable<CalendarRow> custom({
    Expression<int>? id,
    Expression<DateTime>? modifiedAt,
    Expression<String>? name,
    Expression<bool>? enabled,
    Expression<int>? accountId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (name != null) 'name': name,
      if (enabled != null) 'enabled': enabled,
      if (accountId != null) 'account_id': accountId,
    });
  }

  CalendarsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? modifiedAt,
      Value<String>? name,
      Value<bool>? enabled,
      Value<int>? accountId}) {
    return CalendarsCompanion(
      id: id ?? this.id,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      accountId: accountId ?? this.accountId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<int>(accountId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalendarsCompanion(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('enabled: $enabled, ')
          ..write('accountId: $accountId')
          ..write(')'))
        .toString();
  }
}

class $ActivitiesTable extends Activities
    with TableInfo<$ActivitiesTable, ActivityRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ActivitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid, Uint8List> id =
      GeneratedColumn<Uint8List>('id', aliasedName, false,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              clientDefault: () => Uuid.generate().toBytes())
          .withConverter<Uuid>($ActivitiesTable.$converterid);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumnWithTypeConverter<Path, String> path =
      GeneratedColumn<String>('path', aliasedName, false,
              type: DriftSqlType.string, requiredDuringInsert: true)
          .withConverter<Path>($ActivitiesTable.$converterpath);
  static const VerificationMeta _orderMeta = const VerificationMeta('order');
  @override
  late final GeneratedColumnWithTypeConverter<Order, double> order =
      GeneratedColumn<double>('order', aliasedName, false,
              type: DriftSqlType.double,
              requiredDuringInsert: false,
              clientDefault: () => Order.last().value)
          .withConverter<Order>($ActivitiesTable.$converterorder);
  static const VerificationMeta _pomodoroMeta =
      const VerificationMeta('pomodoro');
  @override
  late final GeneratedColumnWithTypeConverter<Duration, int> pomodoro =
      GeneratedColumn<int>('pomodoro', aliasedName, false,
              type: DriftSqlType.int,
              requiredDuringInsert: false,
              defaultValue: const Constant(25 * 60))
          .withConverter<Duration>($ActivitiesTable.$converterpomodoro);
  @override
  List<GeneratedColumn> get $columns =>
      [id, modifiedAt, createdAt, name, path, order, pomodoro];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'activities';
  @override
  VerificationContext validateIntegrity(Insertable<ActivityRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    context.handle(_idMeta, const VerificationResult.success());
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    context.handle(_pathMeta, const VerificationResult.success());
    context.handle(_orderMeta, const VerificationResult.success());
    context.handle(_pomodoroMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ActivityRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ActivityRow(
      id: $ActivitiesTable.$converterid.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}id'])!),
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      path: $ActivitiesTable.$converterpath.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!),
      order: $ActivitiesTable.$converterorder.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}order'])!),
      pomodoro: $ActivitiesTable.$converterpomodoro.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}pomodoro'])!),
    );
  }

  @override
  $ActivitiesTable createAlias(String alias) {
    return $ActivitiesTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converterid = const UuidConverter();
  static TypeConverter<Path, String> $converterpath = const PathConverter();
  static TypeConverter<Order, double> $converterorder = const OrderConverter();
  static TypeConverter<Duration, int> $converterpomodoro =
      const DurationConverter();
}

class ActivityRow extends DataClass implements Insertable<ActivityRow> {
  final Uuid id;
  final DateTime modifiedAt;
  final DateTime createdAt;
  final String name;
  final Path path;
  final Order order;
  final Duration pomodoro;
  const ActivityRow(
      {required this.id,
      required this.modifiedAt,
      required this.createdAt,
      required this.name,
      required this.path,
      required this.order,
      required this.pomodoro});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    {
      map['id'] = Variable<Uint8List>($ActivitiesTable.$converterid.toSql(id));
    }
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['name'] = Variable<String>(name);
    {
      map['path'] =
          Variable<String>($ActivitiesTable.$converterpath.toSql(path));
    }
    {
      map['order'] =
          Variable<double>($ActivitiesTable.$converterorder.toSql(order));
    }
    {
      map['pomodoro'] =
          Variable<int>($ActivitiesTable.$converterpomodoro.toSql(pomodoro));
    }
    return map;
  }

  ActivitiesCompanion toCompanion(bool nullToAbsent) {
    return ActivitiesCompanion(
      id: Value(id),
      modifiedAt: Value(modifiedAt),
      createdAt: Value(createdAt),
      name: Value(name),
      path: Value(path),
      order: Value(order),
      pomodoro: Value(pomodoro),
    );
  }

  factory ActivityRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ActivityRow(
      id: serializer.fromJson<Uuid>(json['id']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
      name: serializer.fromJson<String>(json['name']),
      path: serializer.fromJson<Path>(json['path']),
      order: serializer.fromJson<Order>(json['order']),
      pomodoro: serializer.fromJson<Duration>(json['pomodoro']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uuid>(id),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'created_at': serializer.toJson<DateTime>(createdAt),
      'name': serializer.toJson<String>(name),
      'path': serializer.toJson<Path>(path),
      'order': serializer.toJson<Order>(order),
      'pomodoro': serializer.toJson<Duration>(pomodoro),
    };
  }

  ActivityRow copyWith(
          {Uuid? id,
          DateTime? modifiedAt,
          DateTime? createdAt,
          String? name,
          Path? path,
          Order? order,
          Duration? pomodoro}) =>
      ActivityRow(
        id: id ?? this.id,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        createdAt: createdAt ?? this.createdAt,
        name: name ?? this.name,
        path: path ?? this.path,
        order: order ?? this.order,
        pomodoro: pomodoro ?? this.pomodoro,
      );
  ActivityRow copyWithCompanion(ActivitiesCompanion data) {
    return ActivityRow(
      id: data.id.present ? data.id.value : this.id,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      name: data.name.present ? data.name.value : this.name,
      path: data.path.present ? data.path.value : this.path,
      order: data.order.present ? data.order.value : this.order,
      pomodoro: data.pomodoro.present ? data.pomodoro.value : this.pomodoro,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ActivityRow(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('name: $name, ')
          ..write('path: $path, ')
          ..write('order: $order, ')
          ..write('pomodoro: $pomodoro')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, modifiedAt, createdAt, name, path, order, pomodoro);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ActivityRow &&
          other.id == this.id &&
          other.modifiedAt == this.modifiedAt &&
          other.createdAt == this.createdAt &&
          other.name == this.name &&
          other.path == this.path &&
          other.order == this.order &&
          other.pomodoro == this.pomodoro);
}

class ActivitiesCompanion extends UpdateCompanion<ActivityRow> {
  final Value<Uuid> id;
  final Value<DateTime> modifiedAt;
  final Value<DateTime> createdAt;
  final Value<String> name;
  final Value<Path> path;
  final Value<Order> order;
  final Value<Duration> pomodoro;
  final Value<int> rowid;
  const ActivitiesCompanion({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.name = const Value.absent(),
    this.path = const Value.absent(),
    this.order = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ActivitiesCompanion.insert({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    required String name,
    required Path path,
    this.order = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : name = Value(name),
        path = Value(path);
  static Insertable<ActivityRow> custom({
    Expression<Uint8List>? id,
    Expression<DateTime>? modifiedAt,
    Expression<DateTime>? createdAt,
    Expression<String>? name,
    Expression<String>? path,
    Expression<double>? order,
    Expression<int>? pomodoro,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (name != null) 'name': name,
      if (path != null) 'path': path,
      if (order != null) 'order': order,
      if (pomodoro != null) 'pomodoro': pomodoro,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ActivitiesCompanion copyWith(
      {Value<Uuid>? id,
      Value<DateTime>? modifiedAt,
      Value<DateTime>? createdAt,
      Value<String>? name,
      Value<Path>? path,
      Value<Order>? order,
      Value<Duration>? pomodoro,
      Value<int>? rowid}) {
    return ActivitiesCompanion(
      id: id ?? this.id,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      createdAt: createdAt ?? this.createdAt,
      name: name ?? this.name,
      path: path ?? this.path,
      order: order ?? this.order,
      pomodoro: pomodoro ?? this.pomodoro,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] =
          Variable<Uint8List>($ActivitiesTable.$converterid.toSql(id.value));
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (path.present) {
      map['path'] =
          Variable<String>($ActivitiesTable.$converterpath.toSql(path.value));
    }
    if (order.present) {
      map['order'] =
          Variable<double>($ActivitiesTable.$converterorder.toSql(order.value));
    }
    if (pomodoro.present) {
      map['pomodoro'] = Variable<int>(
          $ActivitiesTable.$converterpomodoro.toSql(pomodoro.value));
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ActivitiesCompanion(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('name: $name, ')
          ..write('path: $path, ')
          ..write('order: $order, ')
          ..write('pomodoro: $pomodoro, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NotesTable extends Notes with TableInfo<$NotesTable, NoteRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid, Uint8List> id =
      GeneratedColumn<Uint8List>('id', aliasedName, false,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              clientDefault: () => Uuid.generate().toBytes())
          .withConverter<Uuid>($NotesTable.$converterid);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid, Uint8List> userId =
      GeneratedColumn<Uint8List>('user_id', aliasedName, false,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              clientDefault: () => Uuid.generate().toBytes())
          .withConverter<Uuid>($NotesTable.$converteruserId);
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
      'body', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orderMeta = const VerificationMeta('order');
  @override
  late final GeneratedColumnWithTypeConverter<Order, double> order =
      GeneratedColumn<double>('order', aliasedName, false,
              type: DriftSqlType.double,
              requiredDuringInsert: false,
              clientDefault: () => Order.first().value)
          .withConverter<Order>($NotesTable.$converterorder);
  static const VerificationMeta _orderedAtMeta =
      const VerificationMeta('orderedAt');
  @override
  late final GeneratedColumn<DateTime> orderedAt = GeneratedColumn<DateTime>(
      'ordered_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _rootMeta = const VerificationMeta('root');
  @override
  late final GeneratedColumn<bool> root = GeneratedColumn<bool>(
      'root', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("root" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
      'pinned', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("pinned" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _privateMeta =
      const VerificationMeta('private');
  @override
  late final GeneratedColumn<bool> private = GeneratedColumn<bool>(
      'private', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("private" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _topicIdMeta =
      const VerificationMeta('topicId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid, Uint8List> topicId =
      GeneratedColumn<Uint8List>('topic_id', aliasedName, false,
              type: DriftSqlType.blob, requiredDuringInsert: true)
          .withConverter<Uuid>($NotesTable.$convertertopicId);
  static const VerificationMeta _activityIdMeta =
      const VerificationMeta('activityId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> activityId =
      GeneratedColumn<Uint8List>('activity_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES activities (id)'))
          .withConverter<Uuid?>($NotesTable.$converteractivityIdn);
  static const VerificationMeta _doAtMeta = const VerificationMeta('doAt');
  @override
  late final GeneratedColumn<DateTime> doAt = GeneratedColumn<DateTime>(
      'do_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _doneAtMeta = const VerificationMeta('doneAt');
  @override
  late final GeneratedColumn<DateTime> doneAt = GeneratedColumn<DateTime>(
      'done_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        modifiedAt,
        createdAt,
        userId,
        body,
        order,
        orderedAt,
        root,
        pinned,
        private,
        topicId,
        activityId,
        doAt,
        doneAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notes';
  @override
  VerificationContext validateIntegrity(Insertable<NoteRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    context.handle(_idMeta, const VerificationResult.success());
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    context.handle(_userIdMeta, const VerificationResult.success());
    if (data.containsKey('body')) {
      context.handle(
          _bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    context.handle(_orderMeta, const VerificationResult.success());
    if (data.containsKey('ordered_at')) {
      context.handle(_orderedAtMeta,
          orderedAt.isAcceptableOrUnknown(data['ordered_at']!, _orderedAtMeta));
    }
    if (data.containsKey('root')) {
      context.handle(
          _rootMeta, root.isAcceptableOrUnknown(data['root']!, _rootMeta));
    }
    if (data.containsKey('pinned')) {
      context.handle(_pinnedMeta,
          pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta));
    }
    if (data.containsKey('private')) {
      context.handle(_privateMeta,
          private.isAcceptableOrUnknown(data['private']!, _privateMeta));
    }
    context.handle(_topicIdMeta, const VerificationResult.success());
    context.handle(_activityIdMeta, const VerificationResult.success());
    if (data.containsKey('do_at')) {
      context.handle(
          _doAtMeta, doAt.isAcceptableOrUnknown(data['do_at']!, _doAtMeta));
    }
    if (data.containsKey('done_at')) {
      context.handle(_doneAtMeta,
          doneAt.isAcceptableOrUnknown(data['done_at']!, _doneAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NoteRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NoteRow(
      id: $NotesTable.$converterid.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}id'])!),
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      userId: $NotesTable.$converteruserId.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}user_id'])!),
      body: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}body'])!,
      order: $NotesTable.$converterorder.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}order'])!),
      orderedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}ordered_at'])!,
      root: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}root'])!,
      pinned: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}pinned'])!,
      private: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}private'])!,
      topicId: $NotesTable.$convertertopicId.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}topic_id'])!),
      activityId: $NotesTable.$converteractivityIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}activity_id'])),
      doAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}do_at']),
      doneAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}done_at']),
    );
  }

  @override
  $NotesTable createAlias(String alias) {
    return $NotesTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converterid = const UuidConverter();
  static TypeConverter<Uuid, Uint8List> $converteruserId =
      const UuidConverter();
  static TypeConverter<Order, double> $converterorder = const OrderConverter();
  static TypeConverter<Uuid, Uint8List> $convertertopicId =
      const UuidConverter();
  static TypeConverter<Uuid, Uint8List> $converteractivityId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $converteractivityIdn =
      NullAwareTypeConverter.wrap($converteractivityId);
}

class NoteRow extends DataClass implements Insertable<NoteRow> {
  final Uuid id;
  final DateTime modifiedAt;
  final DateTime createdAt;
  final Uuid userId;
  final String body;
  final Order order;
  final DateTime orderedAt;
  final bool root;
  final bool pinned;
  final bool private;
  final Uuid topicId;
  final Uuid? activityId;
  final DateTime? doAt;
  final DateTime? doneAt;
  const NoteRow(
      {required this.id,
      required this.modifiedAt,
      required this.createdAt,
      required this.userId,
      required this.body,
      required this.order,
      required this.orderedAt,
      required this.root,
      required this.pinned,
      required this.private,
      required this.topicId,
      this.activityId,
      this.doAt,
      this.doneAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    {
      map['id'] = Variable<Uint8List>($NotesTable.$converterid.toSql(id));
    }
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['created_at'] = Variable<DateTime>(createdAt);
    {
      map['user_id'] =
          Variable<Uint8List>($NotesTable.$converteruserId.toSql(userId));
    }
    map['body'] = Variable<String>(body);
    {
      map['order'] = Variable<double>($NotesTable.$converterorder.toSql(order));
    }
    map['ordered_at'] = Variable<DateTime>(orderedAt);
    map['root'] = Variable<bool>(root);
    map['pinned'] = Variable<bool>(pinned);
    map['private'] = Variable<bool>(private);
    {
      map['topic_id'] =
          Variable<Uint8List>($NotesTable.$convertertopicId.toSql(topicId));
    }
    if (!nullToAbsent || activityId != null) {
      map['activity_id'] = Variable<Uint8List>(
          $NotesTable.$converteractivityIdn.toSql(activityId));
    }
    if (!nullToAbsent || doAt != null) {
      map['do_at'] = Variable<DateTime>(doAt);
    }
    if (!nullToAbsent || doneAt != null) {
      map['done_at'] = Variable<DateTime>(doneAt);
    }
    return map;
  }

  NotesCompanion toCompanion(bool nullToAbsent) {
    return NotesCompanion(
      id: Value(id),
      modifiedAt: Value(modifiedAt),
      createdAt: Value(createdAt),
      userId: Value(userId),
      body: Value(body),
      order: Value(order),
      orderedAt: Value(orderedAt),
      root: Value(root),
      pinned: Value(pinned),
      private: Value(private),
      topicId: Value(topicId),
      activityId: activityId == null && nullToAbsent
          ? const Value.absent()
          : Value(activityId),
      doAt: doAt == null && nullToAbsent ? const Value.absent() : Value(doAt),
      doneAt:
          doneAt == null && nullToAbsent ? const Value.absent() : Value(doneAt),
    );
  }

  factory NoteRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NoteRow(
      id: serializer.fromJson<Uuid>(json['id']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
      userId: serializer.fromJson<Uuid>(json['user_id']),
      body: serializer.fromJson<String>(json['body']),
      order: serializer.fromJson<Order>(json['order']),
      orderedAt: serializer.fromJson<DateTime>(json['ordered_at']),
      root: serializer.fromJson<bool>(json['root']),
      pinned: serializer.fromJson<bool>(json['pinned']),
      private: serializer.fromJson<bool>(json['private']),
      topicId: serializer.fromJson<Uuid>(json['topic_id']),
      activityId: serializer.fromJson<Uuid?>(json['activity_id']),
      doAt: serializer.fromJson<DateTime?>(json['do_at']),
      doneAt: serializer.fromJson<DateTime?>(json['done_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uuid>(id),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'created_at': serializer.toJson<DateTime>(createdAt),
      'user_id': serializer.toJson<Uuid>(userId),
      'body': serializer.toJson<String>(body),
      'order': serializer.toJson<Order>(order),
      'ordered_at': serializer.toJson<DateTime>(orderedAt),
      'root': serializer.toJson<bool>(root),
      'pinned': serializer.toJson<bool>(pinned),
      'private': serializer.toJson<bool>(private),
      'topic_id': serializer.toJson<Uuid>(topicId),
      'activity_id': serializer.toJson<Uuid?>(activityId),
      'do_at': serializer.toJson<DateTime?>(doAt),
      'done_at': serializer.toJson<DateTime?>(doneAt),
    };
  }

  NoteRow copyWith(
          {Uuid? id,
          DateTime? modifiedAt,
          DateTime? createdAt,
          Uuid? userId,
          String? body,
          Order? order,
          DateTime? orderedAt,
          bool? root,
          bool? pinned,
          bool? private,
          Uuid? topicId,
          Value<Uuid?> activityId = const Value.absent(),
          Value<DateTime?> doAt = const Value.absent(),
          Value<DateTime?> doneAt = const Value.absent()}) =>
      NoteRow(
        id: id ?? this.id,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        createdAt: createdAt ?? this.createdAt,
        userId: userId ?? this.userId,
        body: body ?? this.body,
        order: order ?? this.order,
        orderedAt: orderedAt ?? this.orderedAt,
        root: root ?? this.root,
        pinned: pinned ?? this.pinned,
        private: private ?? this.private,
        topicId: topicId ?? this.topicId,
        activityId: activityId.present ? activityId.value : this.activityId,
        doAt: doAt.present ? doAt.value : this.doAt,
        doneAt: doneAt.present ? doneAt.value : this.doneAt,
      );
  NoteRow copyWithCompanion(NotesCompanion data) {
    return NoteRow(
      id: data.id.present ? data.id.value : this.id,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      userId: data.userId.present ? data.userId.value : this.userId,
      body: data.body.present ? data.body.value : this.body,
      order: data.order.present ? data.order.value : this.order,
      orderedAt: data.orderedAt.present ? data.orderedAt.value : this.orderedAt,
      root: data.root.present ? data.root.value : this.root,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
      private: data.private.present ? data.private.value : this.private,
      topicId: data.topicId.present ? data.topicId.value : this.topicId,
      activityId:
          data.activityId.present ? data.activityId.value : this.activityId,
      doAt: data.doAt.present ? data.doAt.value : this.doAt,
      doneAt: data.doneAt.present ? data.doneAt.value : this.doneAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NoteRow(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('userId: $userId, ')
          ..write('body: $body, ')
          ..write('order: $order, ')
          ..write('orderedAt: $orderedAt, ')
          ..write('root: $root, ')
          ..write('pinned: $pinned, ')
          ..write('private: $private, ')
          ..write('topicId: $topicId, ')
          ..write('activityId: $activityId, ')
          ..write('doAt: $doAt, ')
          ..write('doneAt: $doneAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      modifiedAt,
      createdAt,
      userId,
      body,
      order,
      orderedAt,
      root,
      pinned,
      private,
      topicId,
      activityId,
      doAt,
      doneAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NoteRow &&
          other.id == this.id &&
          other.modifiedAt == this.modifiedAt &&
          other.createdAt == this.createdAt &&
          other.userId == this.userId &&
          other.body == this.body &&
          other.order == this.order &&
          other.orderedAt == this.orderedAt &&
          other.root == this.root &&
          other.pinned == this.pinned &&
          other.private == this.private &&
          other.topicId == this.topicId &&
          other.activityId == this.activityId &&
          other.doAt == this.doAt &&
          other.doneAt == this.doneAt);
}

class NotesCompanion extends UpdateCompanion<NoteRow> {
  final Value<Uuid> id;
  final Value<DateTime> modifiedAt;
  final Value<DateTime> createdAt;
  final Value<Uuid> userId;
  final Value<String> body;
  final Value<Order> order;
  final Value<DateTime> orderedAt;
  final Value<bool> root;
  final Value<bool> pinned;
  final Value<bool> private;
  final Value<Uuid> topicId;
  final Value<Uuid?> activityId;
  final Value<DateTime?> doAt;
  final Value<DateTime?> doneAt;
  final Value<int> rowid;
  const NotesCompanion({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.userId = const Value.absent(),
    this.body = const Value.absent(),
    this.order = const Value.absent(),
    this.orderedAt = const Value.absent(),
    this.root = const Value.absent(),
    this.pinned = const Value.absent(),
    this.private = const Value.absent(),
    this.topicId = const Value.absent(),
    this.activityId = const Value.absent(),
    this.doAt = const Value.absent(),
    this.doneAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotesCompanion.insert({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.userId = const Value.absent(),
    required String body,
    this.order = const Value.absent(),
    this.orderedAt = const Value.absent(),
    this.root = const Value.absent(),
    this.pinned = const Value.absent(),
    this.private = const Value.absent(),
    required Uuid topicId,
    this.activityId = const Value.absent(),
    this.doAt = const Value.absent(),
    this.doneAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : body = Value(body),
        topicId = Value(topicId);
  static Insertable<NoteRow> custom({
    Expression<Uint8List>? id,
    Expression<DateTime>? modifiedAt,
    Expression<DateTime>? createdAt,
    Expression<Uint8List>? userId,
    Expression<String>? body,
    Expression<double>? order,
    Expression<DateTime>? orderedAt,
    Expression<bool>? root,
    Expression<bool>? pinned,
    Expression<bool>? private,
    Expression<Uint8List>? topicId,
    Expression<Uint8List>? activityId,
    Expression<DateTime>? doAt,
    Expression<DateTime>? doneAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (createdAt != null) 'created_at': createdAt,
      if (userId != null) 'user_id': userId,
      if (body != null) 'body': body,
      if (order != null) 'order': order,
      if (orderedAt != null) 'ordered_at': orderedAt,
      if (root != null) 'root': root,
      if (pinned != null) 'pinned': pinned,
      if (private != null) 'private': private,
      if (topicId != null) 'topic_id': topicId,
      if (activityId != null) 'activity_id': activityId,
      if (doAt != null) 'do_at': doAt,
      if (doneAt != null) 'done_at': doneAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotesCompanion copyWith(
      {Value<Uuid>? id,
      Value<DateTime>? modifiedAt,
      Value<DateTime>? createdAt,
      Value<Uuid>? userId,
      Value<String>? body,
      Value<Order>? order,
      Value<DateTime>? orderedAt,
      Value<bool>? root,
      Value<bool>? pinned,
      Value<bool>? private,
      Value<Uuid>? topicId,
      Value<Uuid?>? activityId,
      Value<DateTime?>? doAt,
      Value<DateTime?>? doneAt,
      Value<int>? rowid}) {
    return NotesCompanion(
      id: id ?? this.id,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      createdAt: createdAt ?? this.createdAt,
      userId: userId ?? this.userId,
      body: body ?? this.body,
      order: order ?? this.order,
      orderedAt: orderedAt ?? this.orderedAt,
      root: root ?? this.root,
      pinned: pinned ?? this.pinned,
      private: private ?? this.private,
      topicId: topicId ?? this.topicId,
      activityId: activityId ?? this.activityId,
      doAt: doAt ?? this.doAt,
      doneAt: doneAt ?? this.doneAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<Uint8List>($NotesTable.$converterid.toSql(id.value));
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (userId.present) {
      map['user_id'] =
          Variable<Uint8List>($NotesTable.$converteruserId.toSql(userId.value));
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (order.present) {
      map['order'] =
          Variable<double>($NotesTable.$converterorder.toSql(order.value));
    }
    if (orderedAt.present) {
      map['ordered_at'] = Variable<DateTime>(orderedAt.value);
    }
    if (root.present) {
      map['root'] = Variable<bool>(root.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (private.present) {
      map['private'] = Variable<bool>(private.value);
    }
    if (topicId.present) {
      map['topic_id'] = Variable<Uint8List>(
          $NotesTable.$convertertopicId.toSql(topicId.value));
    }
    if (activityId.present) {
      map['activity_id'] = Variable<Uint8List>(
          $NotesTable.$converteractivityIdn.toSql(activityId.value));
    }
    if (doAt.present) {
      map['do_at'] = Variable<DateTime>(doAt.value);
    }
    if (doneAt.present) {
      map['done_at'] = Variable<DateTime>(doneAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotesCompanion(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('createdAt: $createdAt, ')
          ..write('userId: $userId, ')
          ..write('body: $body, ')
          ..write('order: $order, ')
          ..write('orderedAt: $orderedAt, ')
          ..write('root: $root, ')
          ..write('pinned: $pinned, ')
          ..write('private: $private, ')
          ..write('topicId: $topicId, ')
          ..write('activityId: $activityId, ')
          ..write('doAt: $doAt, ')
          ..write('doneAt: $doneAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $EventsTable extends Events with TableInfo<$EventsTable, EventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid, Uint8List> id =
      GeneratedColumn<Uint8List>('id', aliasedName, false,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              clientDefault: () => Uuid.generate().toBytes())
          .withConverter<Uuid>($EventsTable.$converterid);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _startMeta = const VerificationMeta('start');
  @override
  late final GeneratedColumn<DateTime> start = GeneratedColumn<DateTime>(
      'start', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _endMeta = const VerificationMeta('end');
  @override
  late final GeneratedColumn<DateTime> end = GeneratedColumn<DateTime>(
      'end', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _seriesMeta = const VerificationMeta('series');
  @override
  late final GeneratedColumn<String> series = GeneratedColumn<String>(
      'series', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _responseMeta =
      const VerificationMeta('response');
  @override
  late final GeneratedColumnWithTypeConverter<EventResponse, String> response =
      GeneratedColumn<String>('response', aliasedName, false,
              type: DriftSqlType.string,
              requiredDuringInsert: false,
              defaultValue: Constant(EventResponse.accepted.toString()))
          .withConverter<EventResponse>($EventsTable.$converterresponse);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumnWithTypeConverter<EventStatus, String> status =
      GeneratedColumn<String>('status', aliasedName, false,
              type: DriftSqlType.string,
              requiredDuringInsert: false,
              defaultValue: Constant(EventStatus.confirmed.toString()))
          .withConverter<EventStatus>($EventsTable.$converterstatus);
  static const VerificationMeta _visibilityMeta =
      const VerificationMeta('visibility');
  @override
  late final GeneratedColumnWithTypeConverter<EventVisibility, String>
      visibility = GeneratedColumn<String>('visibility', aliasedName, false,
              type: DriftSqlType.string,
              requiredDuringInsert: false,
              defaultValue: Constant(EventVisibility.normal.toString()))
          .withConverter<EventVisibility>($EventsTable.$convertervisibility);
  static const VerificationMeta _availabilityMeta =
      const VerificationMeta('availability');
  @override
  late final GeneratedColumnWithTypeConverter<EventAvailability, String>
      availability = GeneratedColumn<String>('availability', aliasedName, false,
              type: DriftSqlType.string,
              requiredDuringInsert: false,
              defaultValue: Constant(EventAvailability.free.toString()))
          .withConverter<EventAvailability>(
              $EventsTable.$converteravailability);
  static const VerificationMeta _inviteesHiddenMeta =
      const VerificationMeta('inviteesHidden');
  @override
  late final GeneratedColumn<bool> inviteesHidden = GeneratedColumn<bool>(
      'invitees_hidden', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("invitees_hidden" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _activityIdMeta =
      const VerificationMeta('activityId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> activityId =
      GeneratedColumn<Uint8List>('activity_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES activities (id)'))
          .withConverter<Uuid?>($EventsTable.$converteractivityIdn);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        modifiedAt,
        name,
        start,
        end,
        series,
        response,
        status,
        visibility,
        availability,
        inviteesHidden,
        activityId
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'events';
  @override
  VerificationContext validateIntegrity(Insertable<EventRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    context.handle(_idMeta, const VerificationResult.success());
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    }
    if (data.containsKey('start')) {
      context.handle(
          _startMeta, start.isAcceptableOrUnknown(data['start']!, _startMeta));
    } else if (isInserting) {
      context.missing(_startMeta);
    }
    if (data.containsKey('end')) {
      context.handle(
          _endMeta, end.isAcceptableOrUnknown(data['end']!, _endMeta));
    } else if (isInserting) {
      context.missing(_endMeta);
    }
    if (data.containsKey('series')) {
      context.handle(_seriesMeta,
          series.isAcceptableOrUnknown(data['series']!, _seriesMeta));
    }
    context.handle(_responseMeta, const VerificationResult.success());
    context.handle(_statusMeta, const VerificationResult.success());
    context.handle(_visibilityMeta, const VerificationResult.success());
    context.handle(_availabilityMeta, const VerificationResult.success());
    if (data.containsKey('invitees_hidden')) {
      context.handle(
          _inviteesHiddenMeta,
          inviteesHidden.isAcceptableOrUnknown(
              data['invitees_hidden']!, _inviteesHiddenMeta));
    }
    context.handle(_activityIdMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  EventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EventRow(
      id: $EventsTable.$converterid.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}id'])!),
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name']),
      start: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}start'])!,
      end: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}end'])!,
      series: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}series']),
      response: $EventsTable.$converterresponse.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}response'])!),
      status: $EventsTable.$converterstatus.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!),
      visibility: $EventsTable.$convertervisibility.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}visibility'])!),
      availability: $EventsTable.$converteravailability.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}availability'])!),
      inviteesHidden: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}invitees_hidden'])!,
      activityId: $EventsTable.$converteractivityIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}activity_id'])),
    );
  }

  @override
  $EventsTable createAlias(String alias) {
    return $EventsTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converterid = const UuidConverter();
  static JsonTypeConverter2<EventResponse, String, String> $converterresponse =
      const EnumNameConverter<EventResponse>(EventResponse.values);
  static JsonTypeConverter2<EventStatus, String, String> $converterstatus =
      const EnumNameConverter<EventStatus>(EventStatus.values);
  static JsonTypeConverter2<EventVisibility, String, String>
      $convertervisibility =
      const EnumNameConverter<EventVisibility>(EventVisibility.values);
  static JsonTypeConverter2<EventAvailability, String, String>
      $converteravailability =
      const EnumNameConverter<EventAvailability>(EventAvailability.values);
  static TypeConverter<Uuid, Uint8List> $converteractivityId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $converteractivityIdn =
      NullAwareTypeConverter.wrap($converteractivityId);
}

class EventRow extends DataClass implements Insertable<EventRow> {
  final Uuid id;
  final DateTime modifiedAt;
  final String? name;
  final DateTime start;
  final DateTime end;
  final String? series;
  final EventResponse response;
  final EventStatus status;
  final EventVisibility visibility;
  final EventAvailability availability;
  final bool inviteesHidden;
  final Uuid? activityId;
  const EventRow(
      {required this.id,
      required this.modifiedAt,
      this.name,
      required this.start,
      required this.end,
      this.series,
      required this.response,
      required this.status,
      required this.visibility,
      required this.availability,
      required this.inviteesHidden,
      this.activityId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    {
      map['id'] = Variable<Uint8List>($EventsTable.$converterid.toSql(id));
    }
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    map['start'] = Variable<DateTime>(start);
    map['end'] = Variable<DateTime>(end);
    if (!nullToAbsent || series != null) {
      map['series'] = Variable<String>(series);
    }
    {
      map['response'] =
          Variable<String>($EventsTable.$converterresponse.toSql(response));
    }
    {
      map['status'] =
          Variable<String>($EventsTable.$converterstatus.toSql(status));
    }
    {
      map['visibility'] =
          Variable<String>($EventsTable.$convertervisibility.toSql(visibility));
    }
    {
      map['availability'] = Variable<String>(
          $EventsTable.$converteravailability.toSql(availability));
    }
    map['invitees_hidden'] = Variable<bool>(inviteesHidden);
    if (!nullToAbsent || activityId != null) {
      map['activity_id'] = Variable<Uint8List>(
          $EventsTable.$converteractivityIdn.toSql(activityId));
    }
    return map;
  }

  EventsCompanion toCompanion(bool nullToAbsent) {
    return EventsCompanion(
      id: Value(id),
      modifiedAt: Value(modifiedAt),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      start: Value(start),
      end: Value(end),
      series:
          series == null && nullToAbsent ? const Value.absent() : Value(series),
      response: Value(response),
      status: Value(status),
      visibility: Value(visibility),
      availability: Value(availability),
      inviteesHidden: Value(inviteesHidden),
      activityId: activityId == null && nullToAbsent
          ? const Value.absent()
          : Value(activityId),
    );
  }

  factory EventRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EventRow(
      id: serializer.fromJson<Uuid>(json['id']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      name: serializer.fromJson<String?>(json['name']),
      start: serializer.fromJson<DateTime>(json['start']),
      end: serializer.fromJson<DateTime>(json['end']),
      series: serializer.fromJson<String?>(json['series']),
      response: $EventsTable.$converterresponse
          .fromJson(serializer.fromJson<String>(json['response'])),
      status: $EventsTable.$converterstatus
          .fromJson(serializer.fromJson<String>(json['status'])),
      visibility: $EventsTable.$convertervisibility
          .fromJson(serializer.fromJson<String>(json['visibility'])),
      availability: $EventsTable.$converteravailability
          .fromJson(serializer.fromJson<String>(json['availability'])),
      inviteesHidden: serializer.fromJson<bool>(json['invitees_hidden']),
      activityId: serializer.fromJson<Uuid?>(json['activity_id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uuid>(id),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'name': serializer.toJson<String?>(name),
      'start': serializer.toJson<DateTime>(start),
      'end': serializer.toJson<DateTime>(end),
      'series': serializer.toJson<String?>(series),
      'response': serializer
          .toJson<String>($EventsTable.$converterresponse.toJson(response)),
      'status': serializer
          .toJson<String>($EventsTable.$converterstatus.toJson(status)),
      'visibility': serializer
          .toJson<String>($EventsTable.$convertervisibility.toJson(visibility)),
      'availability': serializer.toJson<String>(
          $EventsTable.$converteravailability.toJson(availability)),
      'invitees_hidden': serializer.toJson<bool>(inviteesHidden),
      'activity_id': serializer.toJson<Uuid?>(activityId),
    };
  }

  EventRow copyWith(
          {Uuid? id,
          DateTime? modifiedAt,
          Value<String?> name = const Value.absent(),
          DateTime? start,
          DateTime? end,
          Value<String?> series = const Value.absent(),
          EventResponse? response,
          EventStatus? status,
          EventVisibility? visibility,
          EventAvailability? availability,
          bool? inviteesHidden,
          Value<Uuid?> activityId = const Value.absent()}) =>
      EventRow(
        id: id ?? this.id,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        name: name.present ? name.value : this.name,
        start: start ?? this.start,
        end: end ?? this.end,
        series: series.present ? series.value : this.series,
        response: response ?? this.response,
        status: status ?? this.status,
        visibility: visibility ?? this.visibility,
        availability: availability ?? this.availability,
        inviteesHidden: inviteesHidden ?? this.inviteesHidden,
        activityId: activityId.present ? activityId.value : this.activityId,
      );
  EventRow copyWithCompanion(EventsCompanion data) {
    return EventRow(
      id: data.id.present ? data.id.value : this.id,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      name: data.name.present ? data.name.value : this.name,
      start: data.start.present ? data.start.value : this.start,
      end: data.end.present ? data.end.value : this.end,
      series: data.series.present ? data.series.value : this.series,
      response: data.response.present ? data.response.value : this.response,
      status: data.status.present ? data.status.value : this.status,
      visibility:
          data.visibility.present ? data.visibility.value : this.visibility,
      availability: data.availability.present
          ? data.availability.value
          : this.availability,
      inviteesHidden: data.inviteesHidden.present
          ? data.inviteesHidden.value
          : this.inviteesHidden,
      activityId:
          data.activityId.present ? data.activityId.value : this.activityId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EventRow(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('series: $series, ')
          ..write('response: $response, ')
          ..write('status: $status, ')
          ..write('visibility: $visibility, ')
          ..write('availability: $availability, ')
          ..write('inviteesHidden: $inviteesHidden, ')
          ..write('activityId: $activityId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, modifiedAt, name, start, end, series,
      response, status, visibility, availability, inviteesHidden, activityId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EventRow &&
          other.id == this.id &&
          other.modifiedAt == this.modifiedAt &&
          other.name == this.name &&
          other.start == this.start &&
          other.end == this.end &&
          other.series == this.series &&
          other.response == this.response &&
          other.status == this.status &&
          other.visibility == this.visibility &&
          other.availability == this.availability &&
          other.inviteesHidden == this.inviteesHidden &&
          other.activityId == this.activityId);
}

class EventsCompanion extends UpdateCompanion<EventRow> {
  final Value<Uuid> id;
  final Value<DateTime> modifiedAt;
  final Value<String?> name;
  final Value<DateTime> start;
  final Value<DateTime> end;
  final Value<String?> series;
  final Value<EventResponse> response;
  final Value<EventStatus> status;
  final Value<EventVisibility> visibility;
  final Value<EventAvailability> availability;
  final Value<bool> inviteesHidden;
  final Value<Uuid?> activityId;
  final Value<int> rowid;
  const EventsCompanion({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.name = const Value.absent(),
    this.start = const Value.absent(),
    this.end = const Value.absent(),
    this.series = const Value.absent(),
    this.response = const Value.absent(),
    this.status = const Value.absent(),
    this.visibility = const Value.absent(),
    this.availability = const Value.absent(),
    this.inviteesHidden = const Value.absent(),
    this.activityId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EventsCompanion.insert({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.name = const Value.absent(),
    required DateTime start,
    required DateTime end,
    this.series = const Value.absent(),
    this.response = const Value.absent(),
    this.status = const Value.absent(),
    this.visibility = const Value.absent(),
    this.availability = const Value.absent(),
    this.inviteesHidden = const Value.absent(),
    this.activityId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : start = Value(start),
        end = Value(end);
  static Insertable<EventRow> custom({
    Expression<Uint8List>? id,
    Expression<DateTime>? modifiedAt,
    Expression<String>? name,
    Expression<DateTime>? start,
    Expression<DateTime>? end,
    Expression<String>? series,
    Expression<String>? response,
    Expression<String>? status,
    Expression<String>? visibility,
    Expression<String>? availability,
    Expression<bool>? inviteesHidden,
    Expression<Uint8List>? activityId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (name != null) 'name': name,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
      if (series != null) 'series': series,
      if (response != null) 'response': response,
      if (status != null) 'status': status,
      if (visibility != null) 'visibility': visibility,
      if (availability != null) 'availability': availability,
      if (inviteesHidden != null) 'invitees_hidden': inviteesHidden,
      if (activityId != null) 'activity_id': activityId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EventsCompanion copyWith(
      {Value<Uuid>? id,
      Value<DateTime>? modifiedAt,
      Value<String?>? name,
      Value<DateTime>? start,
      Value<DateTime>? end,
      Value<String?>? series,
      Value<EventResponse>? response,
      Value<EventStatus>? status,
      Value<EventVisibility>? visibility,
      Value<EventAvailability>? availability,
      Value<bool>? inviteesHidden,
      Value<Uuid?>? activityId,
      Value<int>? rowid}) {
    return EventsCompanion(
      id: id ?? this.id,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      name: name ?? this.name,
      start: start ?? this.start,
      end: end ?? this.end,
      series: series ?? this.series,
      response: response ?? this.response,
      status: status ?? this.status,
      visibility: visibility ?? this.visibility,
      availability: availability ?? this.availability,
      inviteesHidden: inviteesHidden ?? this.inviteesHidden,
      activityId: activityId ?? this.activityId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] =
          Variable<Uint8List>($EventsTable.$converterid.toSql(id.value));
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (start.present) {
      map['start'] = Variable<DateTime>(start.value);
    }
    if (end.present) {
      map['end'] = Variable<DateTime>(end.value);
    }
    if (series.present) {
      map['series'] = Variable<String>(series.value);
    }
    if (response.present) {
      map['response'] = Variable<String>(
          $EventsTable.$converterresponse.toSql(response.value));
    }
    if (status.present) {
      map['status'] =
          Variable<String>($EventsTable.$converterstatus.toSql(status.value));
    }
    if (visibility.present) {
      map['visibility'] = Variable<String>(
          $EventsTable.$convertervisibility.toSql(visibility.value));
    }
    if (availability.present) {
      map['availability'] = Variable<String>(
          $EventsTable.$converteravailability.toSql(availability.value));
    }
    if (inviteesHidden.present) {
      map['invitees_hidden'] = Variable<bool>(inviteesHidden.value);
    }
    if (activityId.present) {
      map['activity_id'] = Variable<Uint8List>(
          $EventsTable.$converteractivityIdn.toSql(activityId.value));
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EventsCompanion(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('series: $series, ')
          ..write('response: $response, ')
          ..write('status: $status, ')
          ..write('visibility: $visibility, ')
          ..write('availability: $availability, ')
          ..write('inviteesHidden: $inviteesHidden, ')
          ..write('activityId: $activityId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BudgetsTable extends Budgets with TableInfo<$BudgetsTable, BudgetRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BudgetsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _activityIdMeta =
      const VerificationMeta('activityId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> activityId =
      GeneratedColumn<Uint8List>('activity_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES activities (id)'))
          .withConverter<Uuid?>($BudgetsTable.$converteractivityIdn);
  @override
  List<GeneratedColumn> get $columns => [id, modifiedAt, activityId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'budgets';
  @override
  VerificationContext validateIntegrity(Insertable<BudgetRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    context.handle(_activityIdMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  BudgetRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BudgetRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      activityId: $BudgetsTable.$converteractivityIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}activity_id'])),
    );
  }

  @override
  $BudgetsTable createAlias(String alias) {
    return $BudgetsTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converteractivityId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $converteractivityIdn =
      NullAwareTypeConverter.wrap($converteractivityId);
}

class BudgetRow extends DataClass implements Insertable<BudgetRow> {
  final int id;
  final DateTime modifiedAt;
  final Uuid? activityId;
  const BudgetRow(
      {required this.id, required this.modifiedAt, this.activityId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    if (!nullToAbsent || activityId != null) {
      map['activity_id'] = Variable<Uint8List>(
          $BudgetsTable.$converteractivityIdn.toSql(activityId));
    }
    return map;
  }

  BudgetsCompanion toCompanion(bool nullToAbsent) {
    return BudgetsCompanion(
      id: Value(id),
      modifiedAt: Value(modifiedAt),
      activityId: activityId == null && nullToAbsent
          ? const Value.absent()
          : Value(activityId),
    );
  }

  factory BudgetRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BudgetRow(
      id: serializer.fromJson<int>(json['id']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      activityId: serializer.fromJson<Uuid?>(json['activity_id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'activity_id': serializer.toJson<Uuid?>(activityId),
    };
  }

  BudgetRow copyWith(
          {int? id,
          DateTime? modifiedAt,
          Value<Uuid?> activityId = const Value.absent()}) =>
      BudgetRow(
        id: id ?? this.id,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        activityId: activityId.present ? activityId.value : this.activityId,
      );
  BudgetRow copyWithCompanion(BudgetsCompanion data) {
    return BudgetRow(
      id: data.id.present ? data.id.value : this.id,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      activityId:
          data.activityId.present ? data.activityId.value : this.activityId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BudgetRow(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('activityId: $activityId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, modifiedAt, activityId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BudgetRow &&
          other.id == this.id &&
          other.modifiedAt == this.modifiedAt &&
          other.activityId == this.activityId);
}

class BudgetsCompanion extends UpdateCompanion<BudgetRow> {
  final Value<int> id;
  final Value<DateTime> modifiedAt;
  final Value<Uuid?> activityId;
  const BudgetsCompanion({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.activityId = const Value.absent(),
  });
  BudgetsCompanion.insert({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.activityId = const Value.absent(),
  });
  static Insertable<BudgetRow> custom({
    Expression<int>? id,
    Expression<DateTime>? modifiedAt,
    Expression<Uint8List>? activityId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (activityId != null) 'activity_id': activityId,
    });
  }

  BudgetsCompanion copyWith(
      {Value<int>? id, Value<DateTime>? modifiedAt, Value<Uuid?>? activityId}) {
    return BudgetsCompanion(
      id: id ?? this.id,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      activityId: activityId ?? this.activityId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (activityId.present) {
      map['activity_id'] = Variable<Uint8List>(
          $BudgetsTable.$converteractivityIdn.toSql(activityId.value));
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BudgetsCompanion(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('activityId: $activityId')
          ..write(')'))
        .toString();
  }
}

class $SessionsTable extends Sessions
    with TableInfo<$SessionsTable, SessionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid, Uint8List> id =
      GeneratedColumn<Uint8List>('id', aliasedName, false,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              clientDefault: () => Uuid.generate().toBytes())
          .withConverter<Uuid>($SessionsTable.$converterid);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _activityIdMeta =
      const VerificationMeta('activityId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> activityId =
      GeneratedColumn<Uint8List>('activity_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES activities (id)'))
          .withConverter<Uuid?>($SessionsTable.$converteractivityIdn);
  static const VerificationMeta _startMeta = const VerificationMeta('start');
  @override
  late final GeneratedColumn<DateTime> start = GeneratedColumn<DateTime>(
      'start', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _endMeta = const VerificationMeta('end');
  @override
  late final GeneratedColumn<DateTime> end = GeneratedColumn<DateTime>(
      'end', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _priorityMeta =
      const VerificationMeta('priority');
  @override
  late final GeneratedColumn<int> priority = GeneratedColumn<int>(
      'priority', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _pomodoroMeta =
      const VerificationMeta('pomodoro');
  @override
  late final GeneratedColumnWithTypeConverter<Duration?, int> pomodoro =
      GeneratedColumn<int>('pomodoro', aliasedName, true,
              type: DriftSqlType.int, requiredDuringInsert: false)
          .withConverter<Duration?>($SessionsTable.$converterpomodoron);
  static const VerificationMeta _pomodoroAtMeta =
      const VerificationMeta('pomodoroAt');
  @override
  late final GeneratedColumn<DateTime> pomodoroAt = GeneratedColumn<DateTime>(
      'pomodoro_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, modifiedAt, activityId, start, end, priority, pomodoro, pomodoroAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sessions';
  @override
  VerificationContext validateIntegrity(Insertable<SessionRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    context.handle(_idMeta, const VerificationResult.success());
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    context.handle(_activityIdMeta, const VerificationResult.success());
    if (data.containsKey('start')) {
      context.handle(
          _startMeta, start.isAcceptableOrUnknown(data['start']!, _startMeta));
    } else if (isInserting) {
      context.missing(_startMeta);
    }
    if (data.containsKey('end')) {
      context.handle(
          _endMeta, end.isAcceptableOrUnknown(data['end']!, _endMeta));
    } else if (isInserting) {
      context.missing(_endMeta);
    }
    if (data.containsKey('priority')) {
      context.handle(_priorityMeta,
          priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta));
    }
    context.handle(_pomodoroMeta, const VerificationResult.success());
    if (data.containsKey('pomodoro_at')) {
      context.handle(
          _pomodoroAtMeta,
          pomodoroAt.isAcceptableOrUnknown(
              data['pomodoro_at']!, _pomodoroAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SessionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SessionRow(
      id: $SessionsTable.$converterid.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}id'])!),
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      activityId: $SessionsTable.$converteractivityIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}activity_id'])),
      start: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}start'])!,
      end: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}end'])!,
      priority: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}priority'])!,
      pomodoro: $SessionsTable.$converterpomodoron.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}pomodoro'])),
      pomodoroAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}pomodoro_at']),
    );
  }

  @override
  $SessionsTable createAlias(String alias) {
    return $SessionsTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converterid = const UuidConverter();
  static TypeConverter<Uuid, Uint8List> $converteractivityId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $converteractivityIdn =
      NullAwareTypeConverter.wrap($converteractivityId);
  static TypeConverter<Duration, int> $converterpomodoro =
      const DurationConverter();
  static TypeConverter<Duration?, int?> $converterpomodoron =
      NullAwareTypeConverter.wrap($converterpomodoro);
}

class SessionRow extends DataClass implements Insertable<SessionRow> {
  final Uuid id;
  final DateTime modifiedAt;
  final Uuid? activityId;
  final DateTime start;
  final DateTime end;
  final int priority;
  final Duration? pomodoro;
  final DateTime? pomodoroAt;
  const SessionRow(
      {required this.id,
      required this.modifiedAt,
      this.activityId,
      required this.start,
      required this.end,
      required this.priority,
      this.pomodoro,
      this.pomodoroAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    {
      map['id'] = Variable<Uint8List>($SessionsTable.$converterid.toSql(id));
    }
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    if (!nullToAbsent || activityId != null) {
      map['activity_id'] = Variable<Uint8List>(
          $SessionsTable.$converteractivityIdn.toSql(activityId));
    }
    map['start'] = Variable<DateTime>(start);
    map['end'] = Variable<DateTime>(end);
    map['priority'] = Variable<int>(priority);
    if (!nullToAbsent || pomodoro != null) {
      map['pomodoro'] =
          Variable<int>($SessionsTable.$converterpomodoron.toSql(pomodoro));
    }
    if (!nullToAbsent || pomodoroAt != null) {
      map['pomodoro_at'] = Variable<DateTime>(pomodoroAt);
    }
    return map;
  }

  SessionsCompanion toCompanion(bool nullToAbsent) {
    return SessionsCompanion(
      id: Value(id),
      modifiedAt: Value(modifiedAt),
      activityId: activityId == null && nullToAbsent
          ? const Value.absent()
          : Value(activityId),
      start: Value(start),
      end: Value(end),
      priority: Value(priority),
      pomodoro: pomodoro == null && nullToAbsent
          ? const Value.absent()
          : Value(pomodoro),
      pomodoroAt: pomodoroAt == null && nullToAbsent
          ? const Value.absent()
          : Value(pomodoroAt),
    );
  }

  factory SessionRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SessionRow(
      id: serializer.fromJson<Uuid>(json['id']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      activityId: serializer.fromJson<Uuid?>(json['activity_id']),
      start: serializer.fromJson<DateTime>(json['start']),
      end: serializer.fromJson<DateTime>(json['end']),
      priority: serializer.fromJson<int>(json['priority']),
      pomodoro: serializer.fromJson<Duration?>(json['pomodoro']),
      pomodoroAt: serializer.fromJson<DateTime?>(json['pomodoro_at']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uuid>(id),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'activity_id': serializer.toJson<Uuid?>(activityId),
      'start': serializer.toJson<DateTime>(start),
      'end': serializer.toJson<DateTime>(end),
      'priority': serializer.toJson<int>(priority),
      'pomodoro': serializer.toJson<Duration?>(pomodoro),
      'pomodoro_at': serializer.toJson<DateTime?>(pomodoroAt),
    };
  }

  SessionRow copyWith(
          {Uuid? id,
          DateTime? modifiedAt,
          Value<Uuid?> activityId = const Value.absent(),
          DateTime? start,
          DateTime? end,
          int? priority,
          Value<Duration?> pomodoro = const Value.absent(),
          Value<DateTime?> pomodoroAt = const Value.absent()}) =>
      SessionRow(
        id: id ?? this.id,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        activityId: activityId.present ? activityId.value : this.activityId,
        start: start ?? this.start,
        end: end ?? this.end,
        priority: priority ?? this.priority,
        pomodoro: pomodoro.present ? pomodoro.value : this.pomodoro,
        pomodoroAt: pomodoroAt.present ? pomodoroAt.value : this.pomodoroAt,
      );
  SessionRow copyWithCompanion(SessionsCompanion data) {
    return SessionRow(
      id: data.id.present ? data.id.value : this.id,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      activityId:
          data.activityId.present ? data.activityId.value : this.activityId,
      start: data.start.present ? data.start.value : this.start,
      end: data.end.present ? data.end.value : this.end,
      priority: data.priority.present ? data.priority.value : this.priority,
      pomodoro: data.pomodoro.present ? data.pomodoro.value : this.pomodoro,
      pomodoroAt:
          data.pomodoroAt.present ? data.pomodoroAt.value : this.pomodoroAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SessionRow(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('activityId: $activityId, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('priority: $priority, ')
          ..write('pomodoro: $pomodoro, ')
          ..write('pomodoroAt: $pomodoroAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, modifiedAt, activityId, start, end, priority, pomodoro, pomodoroAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SessionRow &&
          other.id == this.id &&
          other.modifiedAt == this.modifiedAt &&
          other.activityId == this.activityId &&
          other.start == this.start &&
          other.end == this.end &&
          other.priority == this.priority &&
          other.pomodoro == this.pomodoro &&
          other.pomodoroAt == this.pomodoroAt);
}

class SessionsCompanion extends UpdateCompanion<SessionRow> {
  final Value<Uuid> id;
  final Value<DateTime> modifiedAt;
  final Value<Uuid?> activityId;
  final Value<DateTime> start;
  final Value<DateTime> end;
  final Value<int> priority;
  final Value<Duration?> pomodoro;
  final Value<DateTime?> pomodoroAt;
  final Value<int> rowid;
  const SessionsCompanion({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.activityId = const Value.absent(),
    this.start = const Value.absent(),
    this.end = const Value.absent(),
    this.priority = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.pomodoroAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SessionsCompanion.insert({
    this.id = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.activityId = const Value.absent(),
    required DateTime start,
    required DateTime end,
    this.priority = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.pomodoroAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : start = Value(start),
        end = Value(end);
  static Insertable<SessionRow> custom({
    Expression<Uint8List>? id,
    Expression<DateTime>? modifiedAt,
    Expression<Uint8List>? activityId,
    Expression<DateTime>? start,
    Expression<DateTime>? end,
    Expression<int>? priority,
    Expression<int>? pomodoro,
    Expression<DateTime>? pomodoroAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (activityId != null) 'activity_id': activityId,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
      if (priority != null) 'priority': priority,
      if (pomodoro != null) 'pomodoro': pomodoro,
      if (pomodoroAt != null) 'pomodoro_at': pomodoroAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SessionsCompanion copyWith(
      {Value<Uuid>? id,
      Value<DateTime>? modifiedAt,
      Value<Uuid?>? activityId,
      Value<DateTime>? start,
      Value<DateTime>? end,
      Value<int>? priority,
      Value<Duration?>? pomodoro,
      Value<DateTime?>? pomodoroAt,
      Value<int>? rowid}) {
    return SessionsCompanion(
      id: id ?? this.id,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      activityId: activityId ?? this.activityId,
      start: start ?? this.start,
      end: end ?? this.end,
      priority: priority ?? this.priority,
      pomodoro: pomodoro ?? this.pomodoro,
      pomodoroAt: pomodoroAt ?? this.pomodoroAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] =
          Variable<Uint8List>($SessionsTable.$converterid.toSql(id.value));
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (activityId.present) {
      map['activity_id'] = Variable<Uint8List>(
          $SessionsTable.$converteractivityIdn.toSql(activityId.value));
    }
    if (start.present) {
      map['start'] = Variable<DateTime>(start.value);
    }
    if (end.present) {
      map['end'] = Variable<DateTime>(end.value);
    }
    if (priority.present) {
      map['priority'] = Variable<int>(priority.value);
    }
    if (pomodoro.present) {
      map['pomodoro'] = Variable<int>(
          $SessionsTable.$converterpomodoron.toSql(pomodoro.value));
    }
    if (pomodoroAt.present) {
      map['pomodoro_at'] = Variable<DateTime>(pomodoroAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SessionsCompanion(')
          ..write('id: $id, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('activityId: $activityId, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('priority: $priority, ')
          ..write('pomodoro: $pomodoro, ')
          ..write('pomodoroAt: $pomodoroAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BalancesTable extends Balances
    with TableInfo<$BalancesTable, BalanceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BalancesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _dayMeta = const VerificationMeta('day');
  @override
  late final GeneratedColumn<String> day = GeneratedColumn<String>(
      'day', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _activityIdMeta =
      const VerificationMeta('activityId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> activityId =
      GeneratedColumn<Uint8List>('activity_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES activities (id)'))
          .withConverter<Uuid?>($BalancesTable.$converteractivityIdn);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumnWithTypeConverter<BalanceType, int> type =
      GeneratedColumn<int>('type', aliasedName, false,
              type: DriftSqlType.int, requiredDuringInsert: true)
          .withConverter<BalanceType>($BalancesTable.$convertertype);
  static const VerificationMeta _countMeta = const VerificationMeta('count');
  @override
  late final GeneratedColumn<int> count = GeneratedColumn<int>(
      'count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumnWithTypeConverter<Duration, int> time =
      GeneratedColumn<int>('time', aliasedName, false,
              type: DriftSqlType.int,
              requiredDuringInsert: false,
              defaultValue: const Constant(0))
          .withConverter<Duration>($BalancesTable.$convertertime);
  @override
  List<GeneratedColumn> get $columns =>
      [modifiedAt, day, activityId, type, count, time];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'balances';
  @override
  VerificationContext validateIntegrity(Insertable<BalanceRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    if (data.containsKey('day')) {
      context.handle(
          _dayMeta, day.isAcceptableOrUnknown(data['day']!, _dayMeta));
    } else if (isInserting) {
      context.missing(_dayMeta);
    }
    context.handle(_activityIdMeta, const VerificationResult.success());
    context.handle(_typeMeta, const VerificationResult.success());
    if (data.containsKey('count')) {
      context.handle(
          _countMeta, count.isAcceptableOrUnknown(data['count']!, _countMeta));
    }
    context.handle(_timeMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  BalanceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BalanceRow(
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      day: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}day'])!,
      activityId: $BalancesTable.$converteractivityIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}activity_id'])),
      type: $BalancesTable.$convertertype.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}type'])!),
      count: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}count'])!,
      time: $BalancesTable.$convertertime.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}time'])!),
    );
  }

  @override
  $BalancesTable createAlias(String alias) {
    return $BalancesTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converteractivityId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $converteractivityIdn =
      NullAwareTypeConverter.wrap($converteractivityId);
  static JsonTypeConverter2<BalanceType, int, int> $convertertype =
      const EnumIndexConverter<BalanceType>(BalanceType.values);
  static TypeConverter<Duration, int> $convertertime =
      const DurationConverter();
}

class BalanceRow extends DataClass implements Insertable<BalanceRow> {
  final DateTime modifiedAt;
  final String day;
  final Uuid? activityId;
  final BalanceType type;
  final int count;
  final Duration time;
  const BalanceRow(
      {required this.modifiedAt,
      required this.day,
      this.activityId,
      required this.type,
      required this.count,
      required this.time});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['day'] = Variable<String>(day);
    if (!nullToAbsent || activityId != null) {
      map['activity_id'] = Variable<Uint8List>(
          $BalancesTable.$converteractivityIdn.toSql(activityId));
    }
    {
      map['type'] = Variable<int>($BalancesTable.$convertertype.toSql(type));
    }
    map['count'] = Variable<int>(count);
    {
      map['time'] = Variable<int>($BalancesTable.$convertertime.toSql(time));
    }
    return map;
  }

  BalancesCompanion toCompanion(bool nullToAbsent) {
    return BalancesCompanion(
      modifiedAt: Value(modifiedAt),
      day: Value(day),
      activityId: activityId == null && nullToAbsent
          ? const Value.absent()
          : Value(activityId),
      type: Value(type),
      count: Value(count),
      time: Value(time),
    );
  }

  factory BalanceRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BalanceRow(
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      day: serializer.fromJson<String>(json['day']),
      activityId: serializer.fromJson<Uuid?>(json['activity_id']),
      type: $BalancesTable.$convertertype
          .fromJson(serializer.fromJson<int>(json['type'])),
      count: serializer.fromJson<int>(json['count']),
      time: serializer.fromJson<Duration>(json['seconds']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'day': serializer.toJson<String>(day),
      'activity_id': serializer.toJson<Uuid?>(activityId),
      'type':
          serializer.toJson<int>($BalancesTable.$convertertype.toJson(type)),
      'count': serializer.toJson<int>(count),
      'seconds': serializer.toJson<Duration>(time),
    };
  }

  BalanceRow copyWith(
          {DateTime? modifiedAt,
          String? day,
          Value<Uuid?> activityId = const Value.absent(),
          BalanceType? type,
          int? count,
          Duration? time}) =>
      BalanceRow(
        modifiedAt: modifiedAt ?? this.modifiedAt,
        day: day ?? this.day,
        activityId: activityId.present ? activityId.value : this.activityId,
        type: type ?? this.type,
        count: count ?? this.count,
        time: time ?? this.time,
      );
  BalanceRow copyWithCompanion(BalancesCompanion data) {
    return BalanceRow(
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      day: data.day.present ? data.day.value : this.day,
      activityId:
          data.activityId.present ? data.activityId.value : this.activityId,
      type: data.type.present ? data.type.value : this.type,
      count: data.count.present ? data.count.value : this.count,
      time: data.time.present ? data.time.value : this.time,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BalanceRow(')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('day: $day, ')
          ..write('activityId: $activityId, ')
          ..write('type: $type, ')
          ..write('count: $count, ')
          ..write('time: $time')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(modifiedAt, day, activityId, type, count, time);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BalanceRow &&
          other.modifiedAt == this.modifiedAt &&
          other.day == this.day &&
          other.activityId == this.activityId &&
          other.type == this.type &&
          other.count == this.count &&
          other.time == this.time);
}

class BalancesCompanion extends UpdateCompanion<BalanceRow> {
  final Value<DateTime> modifiedAt;
  final Value<String> day;
  final Value<Uuid?> activityId;
  final Value<BalanceType> type;
  final Value<int> count;
  final Value<Duration> time;
  final Value<int> rowid;
  const BalancesCompanion({
    this.modifiedAt = const Value.absent(),
    this.day = const Value.absent(),
    this.activityId = const Value.absent(),
    this.type = const Value.absent(),
    this.count = const Value.absent(),
    this.time = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BalancesCompanion.insert({
    this.modifiedAt = const Value.absent(),
    required String day,
    this.activityId = const Value.absent(),
    required BalanceType type,
    this.count = const Value.absent(),
    this.time = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : day = Value(day),
        type = Value(type);
  static Insertable<BalanceRow> custom({
    Expression<DateTime>? modifiedAt,
    Expression<String>? day,
    Expression<Uint8List>? activityId,
    Expression<int>? type,
    Expression<int>? count,
    Expression<int>? time,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (day != null) 'day': day,
      if (activityId != null) 'activity_id': activityId,
      if (type != null) 'type': type,
      if (count != null) 'count': count,
      if (time != null) 'time': time,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BalancesCompanion copyWith(
      {Value<DateTime>? modifiedAt,
      Value<String>? day,
      Value<Uuid?>? activityId,
      Value<BalanceType>? type,
      Value<int>? count,
      Value<Duration>? time,
      Value<int>? rowid}) {
    return BalancesCompanion(
      modifiedAt: modifiedAt ?? this.modifiedAt,
      day: day ?? this.day,
      activityId: activityId ?? this.activityId,
      type: type ?? this.type,
      count: count ?? this.count,
      time: time ?? this.time,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (day.present) {
      map['day'] = Variable<String>(day.value);
    }
    if (activityId.present) {
      map['activity_id'] = Variable<Uint8List>(
          $BalancesTable.$converteractivityIdn.toSql(activityId.value));
    }
    if (type.present) {
      map['type'] =
          Variable<int>($BalancesTable.$convertertype.toSql(type.value));
    }
    if (count.present) {
      map['count'] = Variable<int>(count.value);
    }
    if (time.present) {
      map['time'] =
          Variable<int>($BalancesTable.$convertertime.toSql(time.value));
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BalancesCompanion(')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('day: $day, ')
          ..write('activityId: $activityId, ')
          ..write('type: $type, ')
          ..write('count: $count, ')
          ..write('time: $time, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$Store extends GeneratedDatabase {
  _$Store(QueryExecutor e) : super(e);
  $StoreManager get managers => $StoreManager(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $AccountsTable accounts = $AccountsTable(this);
  late final $CalendarsTable calendars = $CalendarsTable(this);
  late final $ActivitiesTable activities = $ActivitiesTable(this);
  late final $NotesTable notes = $NotesTable(this);
  late final $EventsTable events = $EventsTable(this);
  late final $BudgetsTable budgets = $BudgetsTable(this);
  late final $SessionsTable sessions = $SessionsTable(this);
  late final $BalancesTable balances = $BalancesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        syncStates,
        accounts,
        calendars,
        activities,
        notes,
        events,
        budgets,
        sessions,
        balances
      ];
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);
}

typedef $$SyncStatesTableCreateCompanionBuilder = SyncStatesCompanion Function({
  required String entity,
  Value<DateTime?> pushedAt,
  Value<String?> lastPulled,
  Value<bool> more,
  Value<int> rowid,
});
typedef $$SyncStatesTableUpdateCompanionBuilder = SyncStatesCompanion Function({
  Value<String> entity,
  Value<DateTime?> pushedAt,
  Value<String?> lastPulled,
  Value<bool> more,
  Value<int> rowid,
});

class $$SyncStatesTableFilterComposer
    extends FilterComposer<_$Store, $SyncStatesTable> {
  $$SyncStatesTableFilterComposer(super.$state);
  ColumnFilters<String> get entity => $state.composableBuilder(
      column: $state.table.entity,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get pushedAt => $state.composableBuilder(
      column: $state.table.pushedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get lastPulled => $state.composableBuilder(
      column: $state.table.lastPulled,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get more => $state.composableBuilder(
      column: $state.table.more,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));
}

class $$SyncStatesTableOrderingComposer
    extends OrderingComposer<_$Store, $SyncStatesTable> {
  $$SyncStatesTableOrderingComposer(super.$state);
  ColumnOrderings<String> get entity => $state.composableBuilder(
      column: $state.table.entity,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get pushedAt => $state.composableBuilder(
      column: $state.table.pushedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get lastPulled => $state.composableBuilder(
      column: $state.table.lastPulled,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get more => $state.composableBuilder(
      column: $state.table.more,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

class $$SyncStatesTableTableManager extends RootTableManager<
    _$Store,
    $SyncStatesTable,
    SyncState,
    $$SyncStatesTableFilterComposer,
    $$SyncStatesTableOrderingComposer,
    $$SyncStatesTableCreateCompanionBuilder,
    $$SyncStatesTableUpdateCompanionBuilder,
    (SyncState, BaseReferences<_$Store, $SyncStatesTable, SyncState>),
    SyncState,
    PrefetchHooks Function()> {
  $$SyncStatesTableTableManager(_$Store db, $SyncStatesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$SyncStatesTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$SyncStatesTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<String> entity = const Value.absent(),
            Value<DateTime?> pushedAt = const Value.absent(),
            Value<String?> lastPulled = const Value.absent(),
            Value<bool> more = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncStatesCompanion(
            entity: entity,
            pushedAt: pushedAt,
            lastPulled: lastPulled,
            more: more,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String entity,
            Value<DateTime?> pushedAt = const Value.absent(),
            Value<String?> lastPulled = const Value.absent(),
            Value<bool> more = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncStatesCompanion.insert(
            entity: entity,
            pushedAt: pushedAt,
            lastPulled: lastPulled,
            more: more,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncStatesTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $SyncStatesTable,
    SyncState,
    $$SyncStatesTableFilterComposer,
    $$SyncStatesTableOrderingComposer,
    $$SyncStatesTableCreateCompanionBuilder,
    $$SyncStatesTableUpdateCompanionBuilder,
    (SyncState, BaseReferences<_$Store, $SyncStatesTable, SyncState>),
    SyncState,
    PrefetchHooks Function()>;
typedef $$AccountsTableCreateCompanionBuilder = AccountsCompanion Function({
  Value<int> id,
  Value<DateTime> modifiedAt,
  required String email,
  required AccountProvider provider,
});
typedef $$AccountsTableUpdateCompanionBuilder = AccountsCompanion Function({
  Value<int> id,
  Value<DateTime> modifiedAt,
  Value<String> email,
  Value<AccountProvider> provider,
});

final class $$AccountsTableReferences
    extends BaseReferences<_$Store, $AccountsTable, AccountRow> {
  $$AccountsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$CalendarsTable, List<CalendarRow>>
      _calendarsRefsTable(_$Store db) => MultiTypedResultKey.fromTable(
          db.calendars,
          aliasName:
              $_aliasNameGenerator(db.accounts.id, db.calendars.accountId));

  $$CalendarsTableProcessedTableManager get calendarsRefs {
    final manager = $$CalendarsTableTableManager($_db, $_db.calendars)
        .filter((f) => f.accountId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_calendarsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$AccountsTableFilterComposer
    extends FilterComposer<_$Store, $AccountsTable> {
  $$AccountsTableFilterComposer(super.$state);
  ColumnFilters<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get email => $state.composableBuilder(
      column: $state.table.email,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<AccountProvider, AccountProvider, String>
      get provider => $state.composableBuilder(
          column: $state.table.provider,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ComposableFilter calendarsRefs(
      ComposableFilter Function($$CalendarsTableFilterComposer f) f) {
    final $$CalendarsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.calendars,
        getReferencedColumn: (t) => t.accountId,
        builder: (joinBuilder, parentComposers) =>
            $$CalendarsTableFilterComposer(ComposerState(
                $state.db, $state.db.calendars, joinBuilder, parentComposers)));
    return f(composer);
  }
}

class $$AccountsTableOrderingComposer
    extends OrderingComposer<_$Store, $AccountsTable> {
  $$AccountsTableOrderingComposer(super.$state);
  ColumnOrderings<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get email => $state.composableBuilder(
      column: $state.table.email,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get provider => $state.composableBuilder(
      column: $state.table.provider,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

class $$AccountsTableTableManager extends RootTableManager<
    _$Store,
    $AccountsTable,
    AccountRow,
    $$AccountsTableFilterComposer,
    $$AccountsTableOrderingComposer,
    $$AccountsTableCreateCompanionBuilder,
    $$AccountsTableUpdateCompanionBuilder,
    (AccountRow, $$AccountsTableReferences),
    AccountRow,
    PrefetchHooks Function({bool calendarsRefs})> {
  $$AccountsTableTableManager(_$Store db, $AccountsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$AccountsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$AccountsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String> email = const Value.absent(),
            Value<AccountProvider> provider = const Value.absent(),
          }) =>
              AccountsCompanion(
            id: id,
            modifiedAt: modifiedAt,
            email: email,
            provider: provider,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            required String email,
            required AccountProvider provider,
          }) =>
              AccountsCompanion.insert(
            id: id,
            modifiedAt: modifiedAt,
            email: email,
            provider: provider,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$AccountsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({calendarsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (calendarsRefs) db.calendars],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (calendarsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$AccountsTableReferences._calendarsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$AccountsTableReferences(db, table, p0)
                                .calendarsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.accountId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$AccountsTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $AccountsTable,
    AccountRow,
    $$AccountsTableFilterComposer,
    $$AccountsTableOrderingComposer,
    $$AccountsTableCreateCompanionBuilder,
    $$AccountsTableUpdateCompanionBuilder,
    (AccountRow, $$AccountsTableReferences),
    AccountRow,
    PrefetchHooks Function({bool calendarsRefs})>;
typedef $$CalendarsTableCreateCompanionBuilder = CalendarsCompanion Function({
  Value<int> id,
  Value<DateTime> modifiedAt,
  required String name,
  required bool enabled,
  required int accountId,
});
typedef $$CalendarsTableUpdateCompanionBuilder = CalendarsCompanion Function({
  Value<int> id,
  Value<DateTime> modifiedAt,
  Value<String> name,
  Value<bool> enabled,
  Value<int> accountId,
});

final class $$CalendarsTableReferences
    extends BaseReferences<_$Store, $CalendarsTable, CalendarRow> {
  $$CalendarsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AccountsTable _accountIdTable(_$Store db) => db.accounts.createAlias(
      $_aliasNameGenerator(db.calendars.accountId, db.accounts.id));

  $$AccountsTableProcessedTableManager? get accountId {
    if ($_item.accountId == null) return null;
    final manager = $$AccountsTableTableManager($_db, $_db.accounts)
        .filter((f) => f.id($_item.accountId!));
    final item = $_typedResult.readTableOrNull(_accountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$CalendarsTableFilterComposer
    extends FilterComposer<_$Store, $CalendarsTable> {
  $$CalendarsTableFilterComposer(super.$state);
  ColumnFilters<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get name => $state.composableBuilder(
      column: $state.table.name,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get enabled => $state.composableBuilder(
      column: $state.table.enabled,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$AccountsTableFilterComposer get accountId {
    final $$AccountsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.accountId,
        referencedTable: $state.db.accounts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$AccountsTableFilterComposer(ComposerState(
                $state.db, $state.db.accounts, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$CalendarsTableOrderingComposer
    extends OrderingComposer<_$Store, $CalendarsTable> {
  $$CalendarsTableOrderingComposer(super.$state);
  ColumnOrderings<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get name => $state.composableBuilder(
      column: $state.table.name,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get enabled => $state.composableBuilder(
      column: $state.table.enabled,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$AccountsTableOrderingComposer get accountId {
    final $$AccountsTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.accountId,
        referencedTable: $state.db.accounts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$AccountsTableOrderingComposer(ComposerState(
                $state.db, $state.db.accounts, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$CalendarsTableTableManager extends RootTableManager<
    _$Store,
    $CalendarsTable,
    CalendarRow,
    $$CalendarsTableFilterComposer,
    $$CalendarsTableOrderingComposer,
    $$CalendarsTableCreateCompanionBuilder,
    $$CalendarsTableUpdateCompanionBuilder,
    (CalendarRow, $$CalendarsTableReferences),
    CalendarRow,
    PrefetchHooks Function({bool accountId})> {
  $$CalendarsTableTableManager(_$Store db, $CalendarsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$CalendarsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$CalendarsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<bool> enabled = const Value.absent(),
            Value<int> accountId = const Value.absent(),
          }) =>
              CalendarsCompanion(
            id: id,
            modifiedAt: modifiedAt,
            name: name,
            enabled: enabled,
            accountId: accountId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            required String name,
            required bool enabled,
            required int accountId,
          }) =>
              CalendarsCompanion.insert(
            id: id,
            modifiedAt: modifiedAt,
            name: name,
            enabled: enabled,
            accountId: accountId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$CalendarsTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({accountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (accountId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.accountId,
                    referencedTable:
                        $$CalendarsTableReferences._accountIdTable(db),
                    referencedColumn:
                        $$CalendarsTableReferences._accountIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$CalendarsTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $CalendarsTable,
    CalendarRow,
    $$CalendarsTableFilterComposer,
    $$CalendarsTableOrderingComposer,
    $$CalendarsTableCreateCompanionBuilder,
    $$CalendarsTableUpdateCompanionBuilder,
    (CalendarRow, $$CalendarsTableReferences),
    CalendarRow,
    PrefetchHooks Function({bool accountId})>;
typedef $$ActivitiesTableCreateCompanionBuilder = ActivitiesCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<DateTime> createdAt,
  required String name,
  required Path path,
  Value<Order> order,
  Value<Duration> pomodoro,
  Value<int> rowid,
});
typedef $$ActivitiesTableUpdateCompanionBuilder = ActivitiesCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<DateTime> createdAt,
  Value<String> name,
  Value<Path> path,
  Value<Order> order,
  Value<Duration> pomodoro,
  Value<int> rowid,
});

final class $$ActivitiesTableReferences
    extends BaseReferences<_$Store, $ActivitiesTable, ActivityRow> {
  $$ActivitiesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$NotesTable, List<NoteRow>> _notesRefsTable(
          _$Store db) =>
      MultiTypedResultKey.fromTable(db.notes,
          aliasName:
              $_aliasNameGenerator(db.activities.id, db.notes.activityId));

  $$NotesTableProcessedTableManager get notesRefs {
    final manager = $$NotesTableTableManager($_db, $_db.notes)
        .filter((f) => f.activityId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_notesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$EventsTable, List<EventRow>> _eventsRefsTable(
          _$Store db) =>
      MultiTypedResultKey.fromTable(db.events,
          aliasName:
              $_aliasNameGenerator(db.activities.id, db.events.activityId));

  $$EventsTableProcessedTableManager get eventsRefs {
    final manager = $$EventsTableTableManager($_db, $_db.events)
        .filter((f) => f.activityId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_eventsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$BudgetsTable, List<BudgetRow>> _budgetsRefsTable(
          _$Store db) =>
      MultiTypedResultKey.fromTable(db.budgets,
          aliasName:
              $_aliasNameGenerator(db.activities.id, db.budgets.activityId));

  $$BudgetsTableProcessedTableManager get budgetsRefs {
    final manager = $$BudgetsTableTableManager($_db, $_db.budgets)
        .filter((f) => f.activityId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_budgetsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$SessionsTable, List<SessionRow>>
      _sessionsRefsTable(_$Store db) => MultiTypedResultKey.fromTable(
          db.sessions,
          aliasName:
              $_aliasNameGenerator(db.activities.id, db.sessions.activityId));

  $$SessionsTableProcessedTableManager get sessionsRefs {
    final manager = $$SessionsTableTableManager($_db, $_db.sessions)
        .filter((f) => f.activityId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_sessionsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$BalancesTable, List<BalanceRow>>
      _balancesRefsTable(_$Store db) => MultiTypedResultKey.fromTable(
          db.balances,
          aliasName:
              $_aliasNameGenerator(db.activities.id, db.balances.activityId));

  $$BalancesTableProcessedTableManager get balancesRefs {
    final manager = $$BalancesTableTableManager($_db, $_db.balances)
        .filter((f) => f.activityId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_balancesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$ActivitiesTableFilterComposer
    extends FilterComposer<_$Store, $ActivitiesTable> {
  $$ActivitiesTableFilterComposer(super.$state);
  ColumnWithTypeConverterFilters<Uuid, Uuid, Uint8List> get id =>
      $state.composableBuilder(
          column: $state.table.id,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get name => $state.composableBuilder(
      column: $state.table.name,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Path, Path, String> get path =>
      $state.composableBuilder(
          column: $state.table.path,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Order, Order, double> get order =>
      $state.composableBuilder(
          column: $state.table.order,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Duration, Duration, int> get pomodoro =>
      $state.composableBuilder(
          column: $state.table.pomodoro,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ComposableFilter notesRefs(
      ComposableFilter Function($$NotesTableFilterComposer f) f) {
    final $$NotesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.notes,
        getReferencedColumn: (t) => t.activityId,
        builder: (joinBuilder, parentComposers) => $$NotesTableFilterComposer(
            ComposerState(
                $state.db, $state.db.notes, joinBuilder, parentComposers)));
    return f(composer);
  }

  ComposableFilter eventsRefs(
      ComposableFilter Function($$EventsTableFilterComposer f) f) {
    final $$EventsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.events,
        getReferencedColumn: (t) => t.activityId,
        builder: (joinBuilder, parentComposers) => $$EventsTableFilterComposer(
            ComposerState(
                $state.db, $state.db.events, joinBuilder, parentComposers)));
    return f(composer);
  }

  ComposableFilter budgetsRefs(
      ComposableFilter Function($$BudgetsTableFilterComposer f) f) {
    final $$BudgetsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.budgets,
        getReferencedColumn: (t) => t.activityId,
        builder: (joinBuilder, parentComposers) => $$BudgetsTableFilterComposer(
            ComposerState(
                $state.db, $state.db.budgets, joinBuilder, parentComposers)));
    return f(composer);
  }

  ComposableFilter sessionsRefs(
      ComposableFilter Function($$SessionsTableFilterComposer f) f) {
    final $$SessionsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.sessions,
        getReferencedColumn: (t) => t.activityId,
        builder: (joinBuilder, parentComposers) =>
            $$SessionsTableFilterComposer(ComposerState(
                $state.db, $state.db.sessions, joinBuilder, parentComposers)));
    return f(composer);
  }

  ComposableFilter balancesRefs(
      ComposableFilter Function($$BalancesTableFilterComposer f) f) {
    final $$BalancesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $state.db.balances,
        getReferencedColumn: (t) => t.activityId,
        builder: (joinBuilder, parentComposers) =>
            $$BalancesTableFilterComposer(ComposerState(
                $state.db, $state.db.balances, joinBuilder, parentComposers)));
    return f(composer);
  }
}

class $$ActivitiesTableOrderingComposer
    extends OrderingComposer<_$Store, $ActivitiesTable> {
  $$ActivitiesTableOrderingComposer(super.$state);
  ColumnOrderings<Uint8List> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get name => $state.composableBuilder(
      column: $state.table.name,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get path => $state.composableBuilder(
      column: $state.table.path,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<double> get order => $state.composableBuilder(
      column: $state.table.order,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get pomodoro => $state.composableBuilder(
      column: $state.table.pomodoro,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

class $$ActivitiesTableTableManager extends RootTableManager<
    _$Store,
    $ActivitiesTable,
    ActivityRow,
    $$ActivitiesTableFilterComposer,
    $$ActivitiesTableOrderingComposer,
    $$ActivitiesTableCreateCompanionBuilder,
    $$ActivitiesTableUpdateCompanionBuilder,
    (ActivityRow, $$ActivitiesTableReferences),
    ActivityRow,
    PrefetchHooks Function(
        {bool notesRefs,
        bool eventsRefs,
        bool budgetsRefs,
        bool sessionsRefs,
        bool balancesRefs})> {
  $$ActivitiesTableTableManager(_$Store db, $ActivitiesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$ActivitiesTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$ActivitiesTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<Path> path = const Value.absent(),
            Value<Order> order = const Value.absent(),
            Value<Duration> pomodoro = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ActivitiesCompanion(
            id: id,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            name: name,
            path: path,
            order: order,
            pomodoro: pomodoro,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            required String name,
            required Path path,
            Value<Order> order = const Value.absent(),
            Value<Duration> pomodoro = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ActivitiesCompanion.insert(
            id: id,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            name: name,
            path: path,
            order: order,
            pomodoro: pomodoro,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$ActivitiesTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: (
              {notesRefs = false,
              eventsRefs = false,
              budgetsRefs = false,
              sessionsRefs = false,
              balancesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (notesRefs) db.notes,
                if (eventsRefs) db.events,
                if (budgetsRefs) db.budgets,
                if (sessionsRefs) db.sessions,
                if (balancesRefs) db.balances
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (notesRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ActivitiesTableReferences._notesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ActivitiesTableReferences(db, table, p0)
                                .notesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.activityId == item.id),
                        typedResults: items),
                  if (eventsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ActivitiesTableReferences._eventsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ActivitiesTableReferences(db, table, p0)
                                .eventsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.activityId == item.id),
                        typedResults: items),
                  if (budgetsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ActivitiesTableReferences._budgetsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ActivitiesTableReferences(db, table, p0)
                                .budgetsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.activityId == item.id),
                        typedResults: items),
                  if (sessionsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ActivitiesTableReferences._sessionsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ActivitiesTableReferences(db, table, p0)
                                .sessionsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.activityId == item.id),
                        typedResults: items),
                  if (balancesRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ActivitiesTableReferences._balancesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ActivitiesTableReferences(db, table, p0)
                                .balancesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.activityId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$ActivitiesTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $ActivitiesTable,
    ActivityRow,
    $$ActivitiesTableFilterComposer,
    $$ActivitiesTableOrderingComposer,
    $$ActivitiesTableCreateCompanionBuilder,
    $$ActivitiesTableUpdateCompanionBuilder,
    (ActivityRow, $$ActivitiesTableReferences),
    ActivityRow,
    PrefetchHooks Function(
        {bool notesRefs,
        bool eventsRefs,
        bool budgetsRefs,
        bool sessionsRefs,
        bool balancesRefs})>;
typedef $$NotesTableCreateCompanionBuilder = NotesCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<DateTime> createdAt,
  Value<Uuid> userId,
  required String body,
  Value<Order> order,
  Value<DateTime> orderedAt,
  Value<bool> root,
  Value<bool> pinned,
  Value<bool> private,
  required Uuid topicId,
  Value<Uuid?> activityId,
  Value<DateTime?> doAt,
  Value<DateTime?> doneAt,
  Value<int> rowid,
});
typedef $$NotesTableUpdateCompanionBuilder = NotesCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<DateTime> createdAt,
  Value<Uuid> userId,
  Value<String> body,
  Value<Order> order,
  Value<DateTime> orderedAt,
  Value<bool> root,
  Value<bool> pinned,
  Value<bool> private,
  Value<Uuid> topicId,
  Value<Uuid?> activityId,
  Value<DateTime?> doAt,
  Value<DateTime?> doneAt,
  Value<int> rowid,
});

final class $$NotesTableReferences
    extends BaseReferences<_$Store, $NotesTable, NoteRow> {
  $$NotesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ActivitiesTable _activityIdTable(_$Store db) => db.activities
      .createAlias($_aliasNameGenerator(db.notes.activityId, db.activities.id));

  $$ActivitiesTableProcessedTableManager? get activityId {
    if ($_item.activityId == null) return null;
    final manager = $$ActivitiesTableTableManager($_db, $_db.activities)
        .filter((f) => f.id($_item.activityId!));
    final item = $_typedResult.readTableOrNull(_activityIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$NotesTableFilterComposer extends FilterComposer<_$Store, $NotesTable> {
  $$NotesTableFilterComposer(super.$state);
  ColumnWithTypeConverterFilters<Uuid, Uuid, Uint8List> get id =>
      $state.composableBuilder(
          column: $state.table.id,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Uuid, Uuid, Uint8List> get userId =>
      $state.composableBuilder(
          column: $state.table.userId,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<String> get body => $state.composableBuilder(
      column: $state.table.body,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Order, Order, double> get order =>
      $state.composableBuilder(
          column: $state.table.order,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get orderedAt => $state.composableBuilder(
      column: $state.table.orderedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get root => $state.composableBuilder(
      column: $state.table.root,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get pinned => $state.composableBuilder(
      column: $state.table.pinned,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get private => $state.composableBuilder(
      column: $state.table.private,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Uuid, Uuid, Uint8List> get topicId =>
      $state.composableBuilder(
          column: $state.table.topicId,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get doAt => $state.composableBuilder(
      column: $state.table.doAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get doneAt => $state.composableBuilder(
      column: $state.table.doneAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$ActivitiesTableFilterComposer get activityId {
    final $$ActivitiesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableFilterComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$NotesTableOrderingComposer
    extends OrderingComposer<_$Store, $NotesTable> {
  $$NotesTableOrderingComposer(super.$state);
  ColumnOrderings<Uint8List> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<Uint8List> get userId => $state.composableBuilder(
      column: $state.table.userId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get body => $state.composableBuilder(
      column: $state.table.body,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<double> get order => $state.composableBuilder(
      column: $state.table.order,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get orderedAt => $state.composableBuilder(
      column: $state.table.orderedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get root => $state.composableBuilder(
      column: $state.table.root,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get pinned => $state.composableBuilder(
      column: $state.table.pinned,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get private => $state.composableBuilder(
      column: $state.table.private,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<Uint8List> get topicId => $state.composableBuilder(
      column: $state.table.topicId,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get doAt => $state.composableBuilder(
      column: $state.table.doAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get doneAt => $state.composableBuilder(
      column: $state.table.doneAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ActivitiesTableOrderingComposer get activityId {
    final $$ActivitiesTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableOrderingComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$NotesTableTableManager extends RootTableManager<
    _$Store,
    $NotesTable,
    NoteRow,
    $$NotesTableFilterComposer,
    $$NotesTableOrderingComposer,
    $$NotesTableCreateCompanionBuilder,
    $$NotesTableUpdateCompanionBuilder,
    (NoteRow, $$NotesTableReferences),
    NoteRow,
    PrefetchHooks Function({bool activityId})> {
  $$NotesTableTableManager(_$Store db, $NotesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$NotesTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$NotesTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<Uuid> userId = const Value.absent(),
            Value<String> body = const Value.absent(),
            Value<Order> order = const Value.absent(),
            Value<DateTime> orderedAt = const Value.absent(),
            Value<bool> root = const Value.absent(),
            Value<bool> pinned = const Value.absent(),
            Value<bool> private = const Value.absent(),
            Value<Uuid> topicId = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
            Value<DateTime?> doAt = const Value.absent(),
            Value<DateTime?> doneAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              NotesCompanion(
            id: id,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            userId: userId,
            body: body,
            order: order,
            orderedAt: orderedAt,
            root: root,
            pinned: pinned,
            private: private,
            topicId: topicId,
            activityId: activityId,
            doAt: doAt,
            doneAt: doneAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<Uuid> userId = const Value.absent(),
            required String body,
            Value<Order> order = const Value.absent(),
            Value<DateTime> orderedAt = const Value.absent(),
            Value<bool> root = const Value.absent(),
            Value<bool> pinned = const Value.absent(),
            Value<bool> private = const Value.absent(),
            required Uuid topicId,
            Value<Uuid?> activityId = const Value.absent(),
            Value<DateTime?> doAt = const Value.absent(),
            Value<DateTime?> doneAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              NotesCompanion.insert(
            id: id,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            userId: userId,
            body: body,
            order: order,
            orderedAt: orderedAt,
            root: root,
            pinned: pinned,
            private: private,
            topicId: topicId,
            activityId: activityId,
            doAt: doAt,
            doneAt: doneAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$NotesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({activityId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (activityId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.activityId,
                    referencedTable:
                        $$NotesTableReferences._activityIdTable(db),
                    referencedColumn:
                        $$NotesTableReferences._activityIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$NotesTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $NotesTable,
    NoteRow,
    $$NotesTableFilterComposer,
    $$NotesTableOrderingComposer,
    $$NotesTableCreateCompanionBuilder,
    $$NotesTableUpdateCompanionBuilder,
    (NoteRow, $$NotesTableReferences),
    NoteRow,
    PrefetchHooks Function({bool activityId})>;
typedef $$EventsTableCreateCompanionBuilder = EventsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<String?> name,
  required DateTime start,
  required DateTime end,
  Value<String?> series,
  Value<EventResponse> response,
  Value<EventStatus> status,
  Value<EventVisibility> visibility,
  Value<EventAvailability> availability,
  Value<bool> inviteesHidden,
  Value<Uuid?> activityId,
  Value<int> rowid,
});
typedef $$EventsTableUpdateCompanionBuilder = EventsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<String?> name,
  Value<DateTime> start,
  Value<DateTime> end,
  Value<String?> series,
  Value<EventResponse> response,
  Value<EventStatus> status,
  Value<EventVisibility> visibility,
  Value<EventAvailability> availability,
  Value<bool> inviteesHidden,
  Value<Uuid?> activityId,
  Value<int> rowid,
});

final class $$EventsTableReferences
    extends BaseReferences<_$Store, $EventsTable, EventRow> {
  $$EventsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ActivitiesTable _activityIdTable(_$Store db) =>
      db.activities.createAlias(
          $_aliasNameGenerator(db.events.activityId, db.activities.id));

  $$ActivitiesTableProcessedTableManager? get activityId {
    if ($_item.activityId == null) return null;
    final manager = $$ActivitiesTableTableManager($_db, $_db.activities)
        .filter((f) => f.id($_item.activityId!));
    final item = $_typedResult.readTableOrNull(_activityIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$EventsTableFilterComposer
    extends FilterComposer<_$Store, $EventsTable> {
  $$EventsTableFilterComposer(super.$state);
  ColumnWithTypeConverterFilters<Uuid, Uuid, Uint8List> get id =>
      $state.composableBuilder(
          column: $state.table.id,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get name => $state.composableBuilder(
      column: $state.table.name,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get start => $state.composableBuilder(
      column: $state.table.start,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get end => $state.composableBuilder(
      column: $state.table.end,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get series => $state.composableBuilder(
      column: $state.table.series,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<EventResponse, EventResponse, String>
      get response => $state.composableBuilder(
          column: $state.table.response,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<EventStatus, EventStatus, String> get status =>
      $state.composableBuilder(
          column: $state.table.status,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<EventVisibility, EventVisibility, String>
      get visibility => $state.composableBuilder(
          column: $state.table.visibility,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<EventAvailability, EventAvailability, String>
      get availability => $state.composableBuilder(
          column: $state.table.availability,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<bool> get inviteesHidden => $state.composableBuilder(
      column: $state.table.inviteesHidden,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$ActivitiesTableFilterComposer get activityId {
    final $$ActivitiesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableFilterComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$EventsTableOrderingComposer
    extends OrderingComposer<_$Store, $EventsTable> {
  $$EventsTableOrderingComposer(super.$state);
  ColumnOrderings<Uint8List> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get name => $state.composableBuilder(
      column: $state.table.name,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get start => $state.composableBuilder(
      column: $state.table.start,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get end => $state.composableBuilder(
      column: $state.table.end,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get series => $state.composableBuilder(
      column: $state.table.series,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get response => $state.composableBuilder(
      column: $state.table.response,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get status => $state.composableBuilder(
      column: $state.table.status,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get visibility => $state.composableBuilder(
      column: $state.table.visibility,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get availability => $state.composableBuilder(
      column: $state.table.availability,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<bool> get inviteesHidden => $state.composableBuilder(
      column: $state.table.inviteesHidden,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ActivitiesTableOrderingComposer get activityId {
    final $$ActivitiesTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableOrderingComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$EventsTableTableManager extends RootTableManager<
    _$Store,
    $EventsTable,
    EventRow,
    $$EventsTableFilterComposer,
    $$EventsTableOrderingComposer,
    $$EventsTableCreateCompanionBuilder,
    $$EventsTableUpdateCompanionBuilder,
    (EventRow, $$EventsTableReferences),
    EventRow,
    PrefetchHooks Function({bool activityId})> {
  $$EventsTableTableManager(_$Store db, $EventsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$EventsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$EventsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String?> name = const Value.absent(),
            Value<DateTime> start = const Value.absent(),
            Value<DateTime> end = const Value.absent(),
            Value<String?> series = const Value.absent(),
            Value<EventResponse> response = const Value.absent(),
            Value<EventStatus> status = const Value.absent(),
            Value<EventVisibility> visibility = const Value.absent(),
            Value<EventAvailability> availability = const Value.absent(),
            Value<bool> inviteesHidden = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              EventsCompanion(
            id: id,
            modifiedAt: modifiedAt,
            name: name,
            start: start,
            end: end,
            series: series,
            response: response,
            status: status,
            visibility: visibility,
            availability: availability,
            inviteesHidden: inviteesHidden,
            activityId: activityId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String?> name = const Value.absent(),
            required DateTime start,
            required DateTime end,
            Value<String?> series = const Value.absent(),
            Value<EventResponse> response = const Value.absent(),
            Value<EventStatus> status = const Value.absent(),
            Value<EventVisibility> visibility = const Value.absent(),
            Value<EventAvailability> availability = const Value.absent(),
            Value<bool> inviteesHidden = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              EventsCompanion.insert(
            id: id,
            modifiedAt: modifiedAt,
            name: name,
            start: start,
            end: end,
            series: series,
            response: response,
            status: status,
            visibility: visibility,
            availability: availability,
            inviteesHidden: inviteesHidden,
            activityId: activityId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$EventsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({activityId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (activityId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.activityId,
                    referencedTable:
                        $$EventsTableReferences._activityIdTable(db),
                    referencedColumn:
                        $$EventsTableReferences._activityIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$EventsTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $EventsTable,
    EventRow,
    $$EventsTableFilterComposer,
    $$EventsTableOrderingComposer,
    $$EventsTableCreateCompanionBuilder,
    $$EventsTableUpdateCompanionBuilder,
    (EventRow, $$EventsTableReferences),
    EventRow,
    PrefetchHooks Function({bool activityId})>;
typedef $$BudgetsTableCreateCompanionBuilder = BudgetsCompanion Function({
  Value<int> id,
  Value<DateTime> modifiedAt,
  Value<Uuid?> activityId,
});
typedef $$BudgetsTableUpdateCompanionBuilder = BudgetsCompanion Function({
  Value<int> id,
  Value<DateTime> modifiedAt,
  Value<Uuid?> activityId,
});

final class $$BudgetsTableReferences
    extends BaseReferences<_$Store, $BudgetsTable, BudgetRow> {
  $$BudgetsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ActivitiesTable _activityIdTable(_$Store db) =>
      db.activities.createAlias(
          $_aliasNameGenerator(db.budgets.activityId, db.activities.id));

  $$ActivitiesTableProcessedTableManager? get activityId {
    if ($_item.activityId == null) return null;
    final manager = $$ActivitiesTableTableManager($_db, $_db.activities)
        .filter((f) => f.id($_item.activityId!));
    final item = $_typedResult.readTableOrNull(_activityIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$BudgetsTableFilterComposer
    extends FilterComposer<_$Store, $BudgetsTable> {
  $$BudgetsTableFilterComposer(super.$state);
  ColumnFilters<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$ActivitiesTableFilterComposer get activityId {
    final $$ActivitiesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableFilterComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$BudgetsTableOrderingComposer
    extends OrderingComposer<_$Store, $BudgetsTable> {
  $$BudgetsTableOrderingComposer(super.$state);
  ColumnOrderings<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ActivitiesTableOrderingComposer get activityId {
    final $$ActivitiesTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableOrderingComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$BudgetsTableTableManager extends RootTableManager<
    _$Store,
    $BudgetsTable,
    BudgetRow,
    $$BudgetsTableFilterComposer,
    $$BudgetsTableOrderingComposer,
    $$BudgetsTableCreateCompanionBuilder,
    $$BudgetsTableUpdateCompanionBuilder,
    (BudgetRow, $$BudgetsTableReferences),
    BudgetRow,
    PrefetchHooks Function({bool activityId})> {
  $$BudgetsTableTableManager(_$Store db, $BudgetsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$BudgetsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$BudgetsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
          }) =>
              BudgetsCompanion(
            id: id,
            modifiedAt: modifiedAt,
            activityId: activityId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
          }) =>
              BudgetsCompanion.insert(
            id: id,
            modifiedAt: modifiedAt,
            activityId: activityId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$BudgetsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({activityId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (activityId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.activityId,
                    referencedTable:
                        $$BudgetsTableReferences._activityIdTable(db),
                    referencedColumn:
                        $$BudgetsTableReferences._activityIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$BudgetsTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $BudgetsTable,
    BudgetRow,
    $$BudgetsTableFilterComposer,
    $$BudgetsTableOrderingComposer,
    $$BudgetsTableCreateCompanionBuilder,
    $$BudgetsTableUpdateCompanionBuilder,
    (BudgetRow, $$BudgetsTableReferences),
    BudgetRow,
    PrefetchHooks Function({bool activityId})>;
typedef $$SessionsTableCreateCompanionBuilder = SessionsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<Uuid?> activityId,
  required DateTime start,
  required DateTime end,
  Value<int> priority,
  Value<Duration?> pomodoro,
  Value<DateTime?> pomodoroAt,
  Value<int> rowid,
});
typedef $$SessionsTableUpdateCompanionBuilder = SessionsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> modifiedAt,
  Value<Uuid?> activityId,
  Value<DateTime> start,
  Value<DateTime> end,
  Value<int> priority,
  Value<Duration?> pomodoro,
  Value<DateTime?> pomodoroAt,
  Value<int> rowid,
});

final class $$SessionsTableReferences
    extends BaseReferences<_$Store, $SessionsTable, SessionRow> {
  $$SessionsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ActivitiesTable _activityIdTable(_$Store db) =>
      db.activities.createAlias(
          $_aliasNameGenerator(db.sessions.activityId, db.activities.id));

  $$ActivitiesTableProcessedTableManager? get activityId {
    if ($_item.activityId == null) return null;
    final manager = $$ActivitiesTableTableManager($_db, $_db.activities)
        .filter((f) => f.id($_item.activityId!));
    final item = $_typedResult.readTableOrNull(_activityIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$SessionsTableFilterComposer
    extends FilterComposer<_$Store, $SessionsTable> {
  $$SessionsTableFilterComposer(super.$state);
  ColumnWithTypeConverterFilters<Uuid, Uuid, Uint8List> get id =>
      $state.composableBuilder(
          column: $state.table.id,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get start => $state.composableBuilder(
      column: $state.table.start,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get end => $state.composableBuilder(
      column: $state.table.end,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<int> get priority => $state.composableBuilder(
      column: $state.table.priority,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Duration?, Duration, int> get pomodoro =>
      $state.composableBuilder(
          column: $state.table.pomodoro,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get pomodoroAt => $state.composableBuilder(
      column: $state.table.pomodoroAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$ActivitiesTableFilterComposer get activityId {
    final $$ActivitiesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableFilterComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$SessionsTableOrderingComposer
    extends OrderingComposer<_$Store, $SessionsTable> {
  $$SessionsTableOrderingComposer(super.$state);
  ColumnOrderings<Uint8List> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get start => $state.composableBuilder(
      column: $state.table.start,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get end => $state.composableBuilder(
      column: $state.table.end,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get priority => $state.composableBuilder(
      column: $state.table.priority,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get pomodoro => $state.composableBuilder(
      column: $state.table.pomodoro,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get pomodoroAt => $state.composableBuilder(
      column: $state.table.pomodoroAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ActivitiesTableOrderingComposer get activityId {
    final $$ActivitiesTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableOrderingComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$SessionsTableTableManager extends RootTableManager<
    _$Store,
    $SessionsTable,
    SessionRow,
    $$SessionsTableFilterComposer,
    $$SessionsTableOrderingComposer,
    $$SessionsTableCreateCompanionBuilder,
    $$SessionsTableUpdateCompanionBuilder,
    (SessionRow, $$SessionsTableReferences),
    SessionRow,
    PrefetchHooks Function({bool activityId})> {
  $$SessionsTableTableManager(_$Store db, $SessionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$SessionsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$SessionsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
            Value<DateTime> start = const Value.absent(),
            Value<DateTime> end = const Value.absent(),
            Value<int> priority = const Value.absent(),
            Value<Duration?> pomodoro = const Value.absent(),
            Value<DateTime?> pomodoroAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SessionsCompanion(
            id: id,
            modifiedAt: modifiedAt,
            activityId: activityId,
            start: start,
            end: end,
            priority: priority,
            pomodoro: pomodoro,
            pomodoroAt: pomodoroAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
            required DateTime start,
            required DateTime end,
            Value<int> priority = const Value.absent(),
            Value<Duration?> pomodoro = const Value.absent(),
            Value<DateTime?> pomodoroAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SessionsCompanion.insert(
            id: id,
            modifiedAt: modifiedAt,
            activityId: activityId,
            start: start,
            end: end,
            priority: priority,
            pomodoro: pomodoro,
            pomodoroAt: pomodoroAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$SessionsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({activityId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (activityId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.activityId,
                    referencedTable:
                        $$SessionsTableReferences._activityIdTable(db),
                    referencedColumn:
                        $$SessionsTableReferences._activityIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$SessionsTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $SessionsTable,
    SessionRow,
    $$SessionsTableFilterComposer,
    $$SessionsTableOrderingComposer,
    $$SessionsTableCreateCompanionBuilder,
    $$SessionsTableUpdateCompanionBuilder,
    (SessionRow, $$SessionsTableReferences),
    SessionRow,
    PrefetchHooks Function({bool activityId})>;
typedef $$BalancesTableCreateCompanionBuilder = BalancesCompanion Function({
  Value<DateTime> modifiedAt,
  required String day,
  Value<Uuid?> activityId,
  required BalanceType type,
  Value<int> count,
  Value<Duration> time,
  Value<int> rowid,
});
typedef $$BalancesTableUpdateCompanionBuilder = BalancesCompanion Function({
  Value<DateTime> modifiedAt,
  Value<String> day,
  Value<Uuid?> activityId,
  Value<BalanceType> type,
  Value<int> count,
  Value<Duration> time,
  Value<int> rowid,
});

final class $$BalancesTableReferences
    extends BaseReferences<_$Store, $BalancesTable, BalanceRow> {
  $$BalancesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ActivitiesTable _activityIdTable(_$Store db) =>
      db.activities.createAlias(
          $_aliasNameGenerator(db.balances.activityId, db.activities.id));

  $$ActivitiesTableProcessedTableManager? get activityId {
    if ($_item.activityId == null) return null;
    final manager = $$ActivitiesTableTableManager($_db, $_db.activities)
        .filter((f) => f.id($_item.activityId!));
    final item = $_typedResult.readTableOrNull(_activityIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$BalancesTableFilterComposer
    extends FilterComposer<_$Store, $BalancesTable> {
  $$BalancesTableFilterComposer(super.$state);
  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get day => $state.composableBuilder(
      column: $state.table.day,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<BalanceType, BalanceType, int> get type =>
      $state.composableBuilder(
          column: $state.table.type,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<int> get count => $state.composableBuilder(
      column: $state.table.count,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnWithTypeConverterFilters<Duration, Duration, int> get time =>
      $state.composableBuilder(
          column: $state.table.time,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  $$ActivitiesTableFilterComposer get activityId {
    final $$ActivitiesTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableFilterComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$BalancesTableOrderingComposer
    extends OrderingComposer<_$Store, $BalancesTable> {
  $$BalancesTableOrderingComposer(super.$state);
  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<String> get day => $state.composableBuilder(
      column: $state.table.day,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get type => $state.composableBuilder(
      column: $state.table.type,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get count => $state.composableBuilder(
      column: $state.table.count,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<int> get time => $state.composableBuilder(
      column: $state.table.time,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ActivitiesTableOrderingComposer get activityId {
    final $$ActivitiesTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.activityId,
        referencedTable: $state.db.activities,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ActivitiesTableOrderingComposer(ComposerState($state.db,
                $state.db.activities, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$BalancesTableTableManager extends RootTableManager<
    _$Store,
    $BalancesTable,
    BalanceRow,
    $$BalancesTableFilterComposer,
    $$BalancesTableOrderingComposer,
    $$BalancesTableCreateCompanionBuilder,
    $$BalancesTableUpdateCompanionBuilder,
    (BalanceRow, $$BalancesTableReferences),
    BalanceRow,
    PrefetchHooks Function({bool activityId})> {
  $$BalancesTableTableManager(_$Store db, $BalancesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$BalancesTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$BalancesTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String> day = const Value.absent(),
            Value<Uuid?> activityId = const Value.absent(),
            Value<BalanceType> type = const Value.absent(),
            Value<int> count = const Value.absent(),
            Value<Duration> time = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BalancesCompanion(
            modifiedAt: modifiedAt,
            day: day,
            activityId: activityId,
            type: type,
            count: count,
            time: time,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<DateTime> modifiedAt = const Value.absent(),
            required String day,
            Value<Uuid?> activityId = const Value.absent(),
            required BalanceType type,
            Value<int> count = const Value.absent(),
            Value<Duration> time = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BalancesCompanion.insert(
            modifiedAt: modifiedAt,
            day: day,
            activityId: activityId,
            type: type,
            count: count,
            time: time,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$BalancesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({activityId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (activityId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.activityId,
                    referencedTable:
                        $$BalancesTableReferences._activityIdTable(db),
                    referencedColumn:
                        $$BalancesTableReferences._activityIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$BalancesTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $BalancesTable,
    BalanceRow,
    $$BalancesTableFilterComposer,
    $$BalancesTableOrderingComposer,
    $$BalancesTableCreateCompanionBuilder,
    $$BalancesTableUpdateCompanionBuilder,
    (BalanceRow, $$BalancesTableReferences),
    BalanceRow,
    PrefetchHooks Function({bool activityId})>;

class $StoreManager {
  final _$Store _db;
  $StoreManager(this._db);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db, _db.accounts);
  $$CalendarsTableTableManager get calendars =>
      $$CalendarsTableTableManager(_db, _db.calendars);
  $$ActivitiesTableTableManager get activities =>
      $$ActivitiesTableTableManager(_db, _db.activities);
  $$NotesTableTableManager get notes =>
      $$NotesTableTableManager(_db, _db.notes);
  $$EventsTableTableManager get events =>
      $$EventsTableTableManager(_db, _db.events);
  $$BudgetsTableTableManager get budgets =>
      $$BudgetsTableTableManager(_db, _db.budgets);
  $$SessionsTableTableManager get sessions =>
      $$SessionsTableTableManager(_db, _db.sessions);
  $$BalancesTableTableManager get balances =>
      $$BalancesTableTableManager(_db, _db.balances);
}
