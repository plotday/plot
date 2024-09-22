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
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
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
  List<GeneratedColumn> get $columns =>
      [id, createdAt, modifiedAt, email, provider];
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
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
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
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
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
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String email;
  final AccountProvider provider;
  const AccountRow(
      {required this.id,
      required this.createdAt,
      required this.modifiedAt,
      required this.email,
      required this.provider});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
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
      createdAt: Value(createdAt),
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
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
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
      'created_at': serializer.toJson<DateTime>(createdAt),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'email': serializer.toJson<String>(email),
      'provider': serializer
          .toJson<String>($AccountsTable.$converterprovider.toJson(provider)),
    };
  }

  AccountRow copyWith(
          {int? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          String? email,
          AccountProvider? provider}) =>
      AccountRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        email: email ?? this.email,
        provider: provider ?? this.provider,
      );
  AccountRow copyWithCompanion(AccountsCompanion data) {
    return AccountRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
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
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('email: $email, ')
          ..write('provider: $provider')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, createdAt, modifiedAt, email, provider);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AccountRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.email == this.email &&
          other.provider == this.provider);
}

class AccountsCompanion extends UpdateCompanion<AccountRow> {
  final Value<int> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<String> email;
  final Value<AccountProvider> provider;
  const AccountsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.email = const Value.absent(),
    this.provider = const Value.absent(),
  });
  AccountsCompanion.insert({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    required String email,
    required AccountProvider provider,
  })  : email = Value(email),
        provider = Value(provider);
  static Insertable<AccountRow> custom({
    Expression<int>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<String>? email,
    Expression<String>? provider,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (email != null) 'email': email,
      if (provider != null) 'provider': provider,
    });
  }

  AccountsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<String>? email,
      Value<AccountProvider>? provider}) {
    return AccountsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
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
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
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
          ..write('createdAt: $createdAt, ')
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
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
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
      [id, createdAt, modifiedAt, name, enabled, accountId];
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
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
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
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
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
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String name;
  final bool enabled;
  final int accountId;
  const CalendarRow(
      {required this.id,
      required this.createdAt,
      required this.modifiedAt,
      required this.name,
      required this.enabled,
      required this.accountId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['name'] = Variable<String>(name);
    map['enabled'] = Variable<bool>(enabled);
    map['account_id'] = Variable<int>(accountId);
    return map;
  }

  CalendarsCompanion toCompanion(bool nullToAbsent) {
    return CalendarsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
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
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
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
      'created_at': serializer.toJson<DateTime>(createdAt),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'name': serializer.toJson<String>(name),
      'enabled': serializer.toJson<bool>(enabled),
      'account_id': serializer.toJson<int>(accountId),
    };
  }

  CalendarRow copyWith(
          {int? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          String? name,
          bool? enabled,
          int? accountId}) =>
      CalendarRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        accountId: accountId ?? this.accountId,
      );
  CalendarRow copyWithCompanion(CalendarsCompanion data) {
    return CalendarRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
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
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('enabled: $enabled, ')
          ..write('accountId: $accountId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, createdAt, modifiedAt, name, enabled, accountId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.name == this.name &&
          other.enabled == this.enabled &&
          other.accountId == this.accountId);
}

class CalendarsCompanion extends UpdateCompanion<CalendarRow> {
  final Value<int> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<String> name;
  final Value<bool> enabled;
  final Value<int> accountId;
  const CalendarsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.name = const Value.absent(),
    this.enabled = const Value.absent(),
    this.accountId = const Value.absent(),
  });
  CalendarsCompanion.insert({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    required String name,
    required bool enabled,
    required int accountId,
  })  : name = Value(name),
        enabled = Value(enabled),
        accountId = Value(accountId);
  static Insertable<CalendarRow> custom({
    Expression<int>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<String>? name,
    Expression<bool>? enabled,
    Expression<int>? accountId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (name != null) 'name': name,
      if (enabled != null) 'enabled': enabled,
      if (accountId != null) 'account_id': accountId,
    });
  }

  CalendarsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<String>? name,
      Value<bool>? enabled,
      Value<int>? accountId}) {
    return CalendarsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
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
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
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
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('enabled: $enabled, ')
          ..write('accountId: $accountId')
          ..write(')'))
        .toString();
  }
}

class $ContextsTable extends Contexts
    with TableInfo<$ContextsTable, ContextRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ContextsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid, Uint8List> id =
      GeneratedColumn<Uint8List>('id', aliasedName, false,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              clientDefault: () => Uuid.generate().toBytes())
          .withConverter<Uuid>($ContextsTable.$converterid);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
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
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumnWithTypeConverter<Path, String> path =
      GeneratedColumn<String>('path', aliasedName, false,
              type: DriftSqlType.string, requiredDuringInsert: true)
          .withConverter<Path>($ContextsTable.$converterpath);
  static const VerificationMeta _orderMeta = const VerificationMeta('order');
  @override
  late final GeneratedColumnWithTypeConverter<Order, double> order =
      GeneratedColumn<double>('order', aliasedName, false,
              type: DriftSqlType.double,
              requiredDuringInsert: false,
              clientDefault: () => Order.last().value)
          .withConverter<Order>($ContextsTable.$converterorder);
  static const VerificationMeta _pomodoroMeta =
      const VerificationMeta('pomodoro');
  @override
  late final GeneratedColumnWithTypeConverter<Duration, int> pomodoro =
      GeneratedColumn<int>('pomodoro', aliasedName, false,
              type: DriftSqlType.int,
              requiredDuringInsert: false,
              defaultValue: const Constant(25 * 60))
          .withConverter<Duration>($ContextsTable.$converterpomodoro);
  @override
  List<GeneratedColumn> get $columns =>
      [id, createdAt, modifiedAt, name, path, order, pomodoro];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'contexts';
  @override
  VerificationContext validateIntegrity(Insertable<ContextRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    context.handle(_idMeta, const VerificationResult.success());
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
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
    context.handle(_pathMeta, const VerificationResult.success());
    context.handle(_orderMeta, const VerificationResult.success());
    context.handle(_pomodoroMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ContextRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ContextRow(
      id: $ContextsTable.$converterid.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}id'])!),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      path: $ContextsTable.$converterpath.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!),
      order: $ContextsTable.$converterorder.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}order'])!),
      pomodoro: $ContextsTable.$converterpomodoro.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}pomodoro'])!),
    );
  }

  @override
  $ContextsTable createAlias(String alias) {
    return $ContextsTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converterid = const UuidConverter();
  static TypeConverter<Path, String> $converterpath = const PathConverter();
  static TypeConverter<Order, double> $converterorder = const OrderConverter();
  static TypeConverter<Duration, int> $converterpomodoro =
      const DurationConverter();
}

class ContextRow extends DataClass implements Insertable<ContextRow> {
  final Uuid id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String name;
  final Path path;
  final Order order;
  final Duration pomodoro;
  const ContextRow(
      {required this.id,
      required this.createdAt,
      required this.modifiedAt,
      required this.name,
      required this.path,
      required this.order,
      required this.pomodoro});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    {
      map['id'] = Variable<Uint8List>($ContextsTable.$converterid.toSql(id));
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['name'] = Variable<String>(name);
    {
      map['path'] = Variable<String>($ContextsTable.$converterpath.toSql(path));
    }
    {
      map['order'] =
          Variable<double>($ContextsTable.$converterorder.toSql(order));
    }
    {
      map['pomodoro'] =
          Variable<int>($ContextsTable.$converterpomodoro.toSql(pomodoro));
    }
    return map;
  }

  ContextsCompanion toCompanion(bool nullToAbsent) {
    return ContextsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      modifiedAt: Value(modifiedAt),
      name: Value(name),
      path: Value(path),
      order: Value(order),
      pomodoro: Value(pomodoro),
    );
  }

  factory ContextRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ContextRow(
      id: serializer.fromJson<Uuid>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
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
      'created_at': serializer.toJson<DateTime>(createdAt),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'name': serializer.toJson<String>(name),
      'path': serializer.toJson<Path>(path),
      'order': serializer.toJson<Order>(order),
      'pomodoro': serializer.toJson<Duration>(pomodoro),
    };
  }

  ContextRow copyWith(
          {Uuid? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          String? name,
          Path? path,
          Order? order,
          Duration? pomodoro}) =>
      ContextRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        name: name ?? this.name,
        path: path ?? this.path,
        order: order ?? this.order,
        pomodoro: pomodoro ?? this.pomodoro,
      );
  ContextRow copyWithCompanion(ContextsCompanion data) {
    return ContextRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      name: data.name.present ? data.name.value : this.name,
      path: data.path.present ? data.path.value : this.path,
      order: data.order.present ? data.order.value : this.order,
      pomodoro: data.pomodoro.present ? data.pomodoro.value : this.pomodoro,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ContextRow(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('path: $path, ')
          ..write('order: $order, ')
          ..write('pomodoro: $pomodoro')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, createdAt, modifiedAt, name, path, order, pomodoro);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ContextRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.name == this.name &&
          other.path == this.path &&
          other.order == this.order &&
          other.pomodoro == this.pomodoro);
}

class ContextsCompanion extends UpdateCompanion<ContextRow> {
  final Value<Uuid> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<String> name;
  final Value<Path> path;
  final Value<Order> order;
  final Value<Duration> pomodoro;
  final Value<int> rowid;
  const ContextsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.name = const Value.absent(),
    this.path = const Value.absent(),
    this.order = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ContextsCompanion.insert({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    required String name,
    required Path path,
    this.order = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : name = Value(name),
        path = Value(path);
  static Insertable<ContextRow> custom({
    Expression<Uint8List>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<String>? name,
    Expression<String>? path,
    Expression<double>? order,
    Expression<int>? pomodoro,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (name != null) 'name': name,
      if (path != null) 'path': path,
      if (order != null) 'order': order,
      if (pomodoro != null) 'pomodoro': pomodoro,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ContextsCompanion copyWith(
      {Value<Uuid>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<String>? name,
      Value<Path>? path,
      Value<Order>? order,
      Value<Duration>? pomodoro,
      Value<int>? rowid}) {
    return ContextsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
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
          Variable<Uint8List>($ContextsTable.$converterid.toSql(id.value));
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (path.present) {
      map['path'] =
          Variable<String>($ContextsTable.$converterpath.toSql(path.value));
    }
    if (order.present) {
      map['order'] =
          Variable<double>($ContextsTable.$converterorder.toSql(order.value));
    }
    if (pomodoro.present) {
      map['pomodoro'] = Variable<int>(
          $ContextsTable.$converterpomodoro.toSql(pomodoro.value));
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ContextsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
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
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
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
  static const VerificationMeta _rootMeta = const VerificationMeta('root');
  @override
  late final GeneratedColumn<bool> root = GeneratedColumn<bool>(
      'root', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("root" IN (0, 1))'),
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
  static const VerificationMeta _contextIdMeta =
      const VerificationMeta('contextId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> contextId =
      GeneratedColumn<Uint8List>('context_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES contexts (id)'))
          .withConverter<Uuid?>($NotesTable.$convertercontextIdn);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        createdAt,
        modifiedAt,
        userId,
        body,
        order,
        root,
        private,
        topicId,
        contextId
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
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    context.handle(_userIdMeta, const VerificationResult.success());
    if (data.containsKey('body')) {
      context.handle(
          _bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    context.handle(_orderMeta, const VerificationResult.success());
    if (data.containsKey('root')) {
      context.handle(
          _rootMeta, root.isAcceptableOrUnknown(data['root']!, _rootMeta));
    }
    if (data.containsKey('private')) {
      context.handle(_privateMeta,
          private.isAcceptableOrUnknown(data['private']!, _privateMeta));
    }
    context.handle(_topicIdMeta, const VerificationResult.success());
    context.handle(_contextIdMeta, const VerificationResult.success());
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
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      userId: $NotesTable.$converteruserId.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}user_id'])!),
      body: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}body'])!,
      order: $NotesTable.$converterorder.fromSql(attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}order'])!),
      root: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}root'])!,
      private: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}private'])!,
      topicId: $NotesTable.$convertertopicId.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}topic_id'])!),
      contextId: $NotesTable.$convertercontextIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}context_id'])),
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
  static TypeConverter<Uuid, Uint8List> $convertercontextId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $convertercontextIdn =
      NullAwareTypeConverter.wrap($convertercontextId);
}

class NoteRow extends DataClass implements Insertable<NoteRow> {
  final Uuid id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final Uuid userId;
  final String body;
  final Order order;
  final bool root;
  final bool private;
  final Uuid topicId;
  final Uuid? contextId;
  const NoteRow(
      {required this.id,
      required this.createdAt,
      required this.modifiedAt,
      required this.userId,
      required this.body,
      required this.order,
      required this.root,
      required this.private,
      required this.topicId,
      this.contextId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    {
      map['id'] = Variable<Uint8List>($NotesTable.$converterid.toSql(id));
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    {
      map['user_id'] =
          Variable<Uint8List>($NotesTable.$converteruserId.toSql(userId));
    }
    map['body'] = Variable<String>(body);
    {
      map['order'] = Variable<double>($NotesTable.$converterorder.toSql(order));
    }
    map['root'] = Variable<bool>(root);
    map['private'] = Variable<bool>(private);
    {
      map['topic_id'] =
          Variable<Uint8List>($NotesTable.$convertertopicId.toSql(topicId));
    }
    if (!nullToAbsent || contextId != null) {
      map['context_id'] = Variable<Uint8List>(
          $NotesTable.$convertercontextIdn.toSql(contextId));
    }
    return map;
  }

  NotesCompanion toCompanion(bool nullToAbsent) {
    return NotesCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      modifiedAt: Value(modifiedAt),
      userId: Value(userId),
      body: Value(body),
      order: Value(order),
      root: Value(root),
      private: Value(private),
      topicId: Value(topicId),
      contextId: contextId == null && nullToAbsent
          ? const Value.absent()
          : Value(contextId),
    );
  }

  factory NoteRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NoteRow(
      id: serializer.fromJson<Uuid>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      userId: serializer.fromJson<Uuid>(json['user_id']),
      body: serializer.fromJson<String>(json['body']),
      order: serializer.fromJson<Order>(json['order']),
      root: serializer.fromJson<bool>(json['root']),
      private: serializer.fromJson<bool>(json['private']),
      topicId: serializer.fromJson<Uuid>(json['topic_id']),
      contextId: serializer.fromJson<Uuid?>(json['context_id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uuid>(id),
      'created_at': serializer.toJson<DateTime>(createdAt),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'user_id': serializer.toJson<Uuid>(userId),
      'body': serializer.toJson<String>(body),
      'order': serializer.toJson<Order>(order),
      'root': serializer.toJson<bool>(root),
      'private': serializer.toJson<bool>(private),
      'topic_id': serializer.toJson<Uuid>(topicId),
      'context_id': serializer.toJson<Uuid?>(contextId),
    };
  }

  NoteRow copyWith(
          {Uuid? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          Uuid? userId,
          String? body,
          Order? order,
          bool? root,
          bool? private,
          Uuid? topicId,
          Value<Uuid?> contextId = const Value.absent()}) =>
      NoteRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        userId: userId ?? this.userId,
        body: body ?? this.body,
        order: order ?? this.order,
        root: root ?? this.root,
        private: private ?? this.private,
        topicId: topicId ?? this.topicId,
        contextId: contextId.present ? contextId.value : this.contextId,
      );
  NoteRow copyWithCompanion(NotesCompanion data) {
    return NoteRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      userId: data.userId.present ? data.userId.value : this.userId,
      body: data.body.present ? data.body.value : this.body,
      order: data.order.present ? data.order.value : this.order,
      root: data.root.present ? data.root.value : this.root,
      private: data.private.present ? data.private.value : this.private,
      topicId: data.topicId.present ? data.topicId.value : this.topicId,
      contextId: data.contextId.present ? data.contextId.value : this.contextId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NoteRow(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('userId: $userId, ')
          ..write('body: $body, ')
          ..write('order: $order, ')
          ..write('root: $root, ')
          ..write('private: $private, ')
          ..write('topicId: $topicId, ')
          ..write('contextId: $contextId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, createdAt, modifiedAt, userId, body,
      order, root, private, topicId, contextId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NoteRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.userId == this.userId &&
          other.body == this.body &&
          other.order == this.order &&
          other.root == this.root &&
          other.private == this.private &&
          other.topicId == this.topicId &&
          other.contextId == this.contextId);
}

class NotesCompanion extends UpdateCompanion<NoteRow> {
  final Value<Uuid> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<Uuid> userId;
  final Value<String> body;
  final Value<Order> order;
  final Value<bool> root;
  final Value<bool> private;
  final Value<Uuid> topicId;
  final Value<Uuid?> contextId;
  final Value<int> rowid;
  const NotesCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.userId = const Value.absent(),
    this.body = const Value.absent(),
    this.order = const Value.absent(),
    this.root = const Value.absent(),
    this.private = const Value.absent(),
    this.topicId = const Value.absent(),
    this.contextId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotesCompanion.insert({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.userId = const Value.absent(),
    required String body,
    this.order = const Value.absent(),
    this.root = const Value.absent(),
    this.private = const Value.absent(),
    required Uuid topicId,
    this.contextId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : body = Value(body),
        topicId = Value(topicId);
  static Insertable<NoteRow> custom({
    Expression<Uint8List>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<Uint8List>? userId,
    Expression<String>? body,
    Expression<double>? order,
    Expression<bool>? root,
    Expression<bool>? private,
    Expression<Uint8List>? topicId,
    Expression<Uint8List>? contextId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (userId != null) 'user_id': userId,
      if (body != null) 'body': body,
      if (order != null) 'order': order,
      if (root != null) 'root': root,
      if (private != null) 'private': private,
      if (topicId != null) 'topic_id': topicId,
      if (contextId != null) 'context_id': contextId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotesCompanion copyWith(
      {Value<Uuid>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<Uuid>? userId,
      Value<String>? body,
      Value<Order>? order,
      Value<bool>? root,
      Value<bool>? private,
      Value<Uuid>? topicId,
      Value<Uuid?>? contextId,
      Value<int>? rowid}) {
    return NotesCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      userId: userId ?? this.userId,
      body: body ?? this.body,
      order: order ?? this.order,
      root: root ?? this.root,
      private: private ?? this.private,
      topicId: topicId ?? this.topicId,
      contextId: contextId ?? this.contextId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<Uint8List>($NotesTable.$converterid.toSql(id.value));
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
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
    if (root.present) {
      map['root'] = Variable<bool>(root.value);
    }
    if (private.present) {
      map['private'] = Variable<bool>(private.value);
    }
    if (topicId.present) {
      map['topic_id'] = Variable<Uint8List>(
          $NotesTable.$convertertopicId.toSql(topicId.value));
    }
    if (contextId.present) {
      map['context_id'] = Variable<Uint8List>(
          $NotesTable.$convertercontextIdn.toSql(contextId.value));
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
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('userId: $userId, ')
          ..write('body: $body, ')
          ..write('order: $order, ')
          ..write('root: $root, ')
          ..write('private: $private, ')
          ..write('topicId: $topicId, ')
          ..write('contextId: $contextId, ')
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
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
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
              type: DriftSqlType.string, requiredDuringInsert: true)
          .withConverter<EventResponse>($EventsTable.$converterresponse);
  static const VerificationMeta _contextIdMeta =
      const VerificationMeta('contextId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> contextId =
      GeneratedColumn<Uint8List>('context_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES contexts (id)'))
          .withConverter<Uuid?>($EventsTable.$convertercontextIdn);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        createdAt,
        modifiedAt,
        name,
        start,
        end,
        series,
        response,
        contextId
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
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
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
    context.handle(_contextIdMeta, const VerificationResult.success());
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
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
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
      contextId: $EventsTable.$convertercontextIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}context_id'])),
    );
  }

  @override
  $EventsTable createAlias(String alias) {
    return $EventsTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $converterid = const UuidConverter();
  static JsonTypeConverter2<EventResponse, String, String> $converterresponse =
      const EnumNameConverter<EventResponse>(EventResponse.values);
  static TypeConverter<Uuid, Uint8List> $convertercontextId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $convertercontextIdn =
      NullAwareTypeConverter.wrap($convertercontextId);
}

class EventRow extends DataClass implements Insertable<EventRow> {
  final Uuid id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String? name;
  final DateTime start;
  final DateTime end;
  final String? series;
  final EventResponse response;
  final Uuid? contextId;
  const EventRow(
      {required this.id,
      required this.createdAt,
      required this.modifiedAt,
      this.name,
      required this.start,
      required this.end,
      this.series,
      required this.response,
      this.contextId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    {
      map['id'] = Variable<Uint8List>($EventsTable.$converterid.toSql(id));
    }
    map['created_at'] = Variable<DateTime>(createdAt);
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
    if (!nullToAbsent || contextId != null) {
      map['context_id'] = Variable<Uint8List>(
          $EventsTable.$convertercontextIdn.toSql(contextId));
    }
    return map;
  }

  EventsCompanion toCompanion(bool nullToAbsent) {
    return EventsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      modifiedAt: Value(modifiedAt),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      start: Value(start),
      end: Value(end),
      series:
          series == null && nullToAbsent ? const Value.absent() : Value(series),
      response: Value(response),
      contextId: contextId == null && nullToAbsent
          ? const Value.absent()
          : Value(contextId),
    );
  }

  factory EventRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EventRow(
      id: serializer.fromJson<Uuid>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      name: serializer.fromJson<String?>(json['name']),
      start: serializer.fromJson<DateTime>(json['start']),
      end: serializer.fromJson<DateTime>(json['end']),
      series: serializer.fromJson<String?>(json['series']),
      response: $EventsTable.$converterresponse
          .fromJson(serializer.fromJson<String>(json['response'])),
      contextId: serializer.fromJson<Uuid?>(json['context_id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uuid>(id),
      'created_at': serializer.toJson<DateTime>(createdAt),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'name': serializer.toJson<String?>(name),
      'start': serializer.toJson<DateTime>(start),
      'end': serializer.toJson<DateTime>(end),
      'series': serializer.toJson<String?>(series),
      'response': serializer
          .toJson<String>($EventsTable.$converterresponse.toJson(response)),
      'context_id': serializer.toJson<Uuid?>(contextId),
    };
  }

  EventRow copyWith(
          {Uuid? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          Value<String?> name = const Value.absent(),
          DateTime? start,
          DateTime? end,
          Value<String?> series = const Value.absent(),
          EventResponse? response,
          Value<Uuid?> contextId = const Value.absent()}) =>
      EventRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        name: name.present ? name.value : this.name,
        start: start ?? this.start,
        end: end ?? this.end,
        series: series.present ? series.value : this.series,
        response: response ?? this.response,
        contextId: contextId.present ? contextId.value : this.contextId,
      );
  EventRow copyWithCompanion(EventsCompanion data) {
    return EventRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      name: data.name.present ? data.name.value : this.name,
      start: data.start.present ? data.start.value : this.start,
      end: data.end.present ? data.end.value : this.end,
      series: data.series.present ? data.series.value : this.series,
      response: data.response.present ? data.response.value : this.response,
      contextId: data.contextId.present ? data.contextId.value : this.contextId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EventRow(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('series: $series, ')
          ..write('response: $response, ')
          ..write('contextId: $contextId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, createdAt, modifiedAt, name, start, end, series, response, contextId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EventRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.name == this.name &&
          other.start == this.start &&
          other.end == this.end &&
          other.series == this.series &&
          other.response == this.response &&
          other.contextId == this.contextId);
}

class EventsCompanion extends UpdateCompanion<EventRow> {
  final Value<Uuid> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<String?> name;
  final Value<DateTime> start;
  final Value<DateTime> end;
  final Value<String?> series;
  final Value<EventResponse> response;
  final Value<Uuid?> contextId;
  final Value<int> rowid;
  const EventsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.name = const Value.absent(),
    this.start = const Value.absent(),
    this.end = const Value.absent(),
    this.series = const Value.absent(),
    this.response = const Value.absent(),
    this.contextId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EventsCompanion.insert({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.name = const Value.absent(),
    required DateTime start,
    required DateTime end,
    this.series = const Value.absent(),
    required EventResponse response,
    this.contextId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : start = Value(start),
        end = Value(end),
        response = Value(response);
  static Insertable<EventRow> custom({
    Expression<Uint8List>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<String>? name,
    Expression<DateTime>? start,
    Expression<DateTime>? end,
    Expression<String>? series,
    Expression<String>? response,
    Expression<Uint8List>? contextId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (name != null) 'name': name,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
      if (series != null) 'series': series,
      if (response != null) 'response': response,
      if (contextId != null) 'context_id': contextId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EventsCompanion copyWith(
      {Value<Uuid>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<String?>? name,
      Value<DateTime>? start,
      Value<DateTime>? end,
      Value<String?>? series,
      Value<EventResponse>? response,
      Value<Uuid?>? contextId,
      Value<int>? rowid}) {
    return EventsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      name: name ?? this.name,
      start: start ?? this.start,
      end: end ?? this.end,
      series: series ?? this.series,
      response: response ?? this.response,
      contextId: contextId ?? this.contextId,
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
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
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
    if (contextId.present) {
      map['context_id'] = Variable<Uint8List>(
          $EventsTable.$convertercontextIdn.toSql(contextId.value));
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
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('name: $name, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('series: $series, ')
          ..write('response: $response, ')
          ..write('contextId: $contextId, ')
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
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _contextIdMeta =
      const VerificationMeta('contextId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> contextId =
      GeneratedColumn<Uint8List>('context_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES contexts (id)'))
          .withConverter<Uuid?>($BudgetsTable.$convertercontextIdn);
  @override
  List<GeneratedColumn> get $columns => [id, createdAt, modifiedAt, contextId];
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
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    context.handle(_contextIdMeta, const VerificationResult.success());
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
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      contextId: $BudgetsTable.$convertercontextIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}context_id'])),
    );
  }

  @override
  $BudgetsTable createAlias(String alias) {
    return $BudgetsTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $convertercontextId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $convertercontextIdn =
      NullAwareTypeConverter.wrap($convertercontextId);
}

class BudgetRow extends DataClass implements Insertable<BudgetRow> {
  final int id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final Uuid? contextId;
  const BudgetRow(
      {required this.id,
      required this.createdAt,
      required this.modifiedAt,
      this.contextId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    if (!nullToAbsent || contextId != null) {
      map['context_id'] = Variable<Uint8List>(
          $BudgetsTable.$convertercontextIdn.toSql(contextId));
    }
    return map;
  }

  BudgetsCompanion toCompanion(bool nullToAbsent) {
    return BudgetsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      modifiedAt: Value(modifiedAt),
      contextId: contextId == null && nullToAbsent
          ? const Value.absent()
          : Value(contextId),
    );
  }

  factory BudgetRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BudgetRow(
      id: serializer.fromJson<int>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      contextId: serializer.fromJson<Uuid?>(json['context_id']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'created_at': serializer.toJson<DateTime>(createdAt),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'context_id': serializer.toJson<Uuid?>(contextId),
    };
  }

  BudgetRow copyWith(
          {int? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          Value<Uuid?> contextId = const Value.absent()}) =>
      BudgetRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        contextId: contextId.present ? contextId.value : this.contextId,
      );
  BudgetRow copyWithCompanion(BudgetsCompanion data) {
    return BudgetRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      contextId: data.contextId.present ? data.contextId.value : this.contextId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BudgetRow(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('contextId: $contextId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, createdAt, modifiedAt, contextId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BudgetRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.contextId == this.contextId);
}

class BudgetsCompanion extends UpdateCompanion<BudgetRow> {
  final Value<int> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<Uuid?> contextId;
  const BudgetsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.contextId = const Value.absent(),
  });
  BudgetsCompanion.insert({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.contextId = const Value.absent(),
  });
  static Insertable<BudgetRow> custom({
    Expression<int>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<Uint8List>? contextId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (contextId != null) 'context_id': contextId,
    });
  }

  BudgetsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<Uuid?>? contextId}) {
    return BudgetsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      contextId: contextId ?? this.contextId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (contextId.present) {
      map['context_id'] = Variable<Uint8List>(
          $BudgetsTable.$convertercontextIdn.toSql(contextId.value));
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BudgetsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('contextId: $contextId')
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
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _contextIdMeta =
      const VerificationMeta('contextId');
  @override
  late final GeneratedColumnWithTypeConverter<Uuid?, Uint8List> contextId =
      GeneratedColumn<Uint8List>('context_id', aliasedName, true,
              type: DriftSqlType.blob,
              requiredDuringInsert: false,
              defaultConstraints: GeneratedColumn.constraintIsAlways(
                  'REFERENCES contexts (id)'))
          .withConverter<Uuid?>($SessionsTable.$convertercontextIdn);
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
  static const VerificationMeta _pomodoroRemainingMeta =
      const VerificationMeta('pomodoroRemaining');
  @override
  late final GeneratedColumnWithTypeConverter<Duration?, int>
      pomodoroRemaining = GeneratedColumn<int>(
              'pomodoro_remaining', aliasedName, true,
              type: DriftSqlType.int, requiredDuringInsert: false)
          .withConverter<Duration?>(
              $SessionsTable.$converterpomodoroRemainingn);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        createdAt,
        modifiedAt,
        contextId,
        start,
        end,
        priority,
        pomodoro,
        pomodoroRemaining
      ];
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
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    }
    context.handle(_contextIdMeta, const VerificationResult.success());
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
    context.handle(_pomodoroRemainingMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SessionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SessionRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      contextId: $SessionsTable.$convertercontextIdn.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}context_id'])),
      start: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}start'])!,
      end: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}end'])!,
      priority: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}priority'])!,
      pomodoro: $SessionsTable.$converterpomodoron.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}pomodoro'])),
      pomodoroRemaining: $SessionsTable.$converterpomodoroRemainingn.fromSql(
          attachedDatabase.typeMapping.read(
              DriftSqlType.int, data['${effectivePrefix}pomodoro_remaining'])),
    );
  }

  @override
  $SessionsTable createAlias(String alias) {
    return $SessionsTable(attachedDatabase, alias);
  }

  static TypeConverter<Uuid, Uint8List> $convertercontextId =
      const UuidConverter();
  static TypeConverter<Uuid?, Uint8List?> $convertercontextIdn =
      NullAwareTypeConverter.wrap($convertercontextId);
  static TypeConverter<Duration, int> $converterpomodoro =
      const DurationConverter();
  static TypeConverter<Duration?, int?> $converterpomodoron =
      NullAwareTypeConverter.wrap($converterpomodoro);
  static TypeConverter<Duration, int> $converterpomodoroRemaining =
      const DurationConverter();
  static TypeConverter<Duration?, int?> $converterpomodoroRemainingn =
      NullAwareTypeConverter.wrap($converterpomodoroRemaining);
}

class SessionRow extends DataClass implements Insertable<SessionRow> {
  final int id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final Uuid? contextId;
  final DateTime start;
  final DateTime end;
  final int priority;
  final Duration? pomodoro;
  final Duration? pomodoroRemaining;
  const SessionRow(
      {required this.id,
      required this.createdAt,
      required this.modifiedAt,
      this.contextId,
      required this.start,
      required this.end,
      required this.priority,
      this.pomodoro,
      this.pomodoroRemaining});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    if (!nullToAbsent || contextId != null) {
      map['context_id'] = Variable<Uint8List>(
          $SessionsTable.$convertercontextIdn.toSql(contextId));
    }
    map['start'] = Variable<DateTime>(start);
    map['end'] = Variable<DateTime>(end);
    map['priority'] = Variable<int>(priority);
    if (!nullToAbsent || pomodoro != null) {
      map['pomodoro'] =
          Variable<int>($SessionsTable.$converterpomodoron.toSql(pomodoro));
    }
    if (!nullToAbsent || pomodoroRemaining != null) {
      map['pomodoro_remaining'] = Variable<int>(
          $SessionsTable.$converterpomodoroRemainingn.toSql(pomodoroRemaining));
    }
    return map;
  }

  SessionsCompanion toCompanion(bool nullToAbsent) {
    return SessionsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      modifiedAt: Value(modifiedAt),
      contextId: contextId == null && nullToAbsent
          ? const Value.absent()
          : Value(contextId),
      start: Value(start),
      end: Value(end),
      priority: Value(priority),
      pomodoro: pomodoro == null && nullToAbsent
          ? const Value.absent()
          : Value(pomodoro),
      pomodoroRemaining: pomodoroRemaining == null && nullToAbsent
          ? const Value.absent()
          : Value(pomodoroRemaining),
    );
  }

  factory SessionRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SessionRow(
      id: serializer.fromJson<int>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['created_at']),
      modifiedAt: serializer.fromJson<DateTime>(json['modified_at']),
      contextId: serializer.fromJson<Uuid?>(json['context_id']),
      start: serializer.fromJson<DateTime>(json['start']),
      end: serializer.fromJson<DateTime>(json['end']),
      priority: serializer.fromJson<int>(json['priority']),
      pomodoro: serializer.fromJson<Duration?>(json['pomodoro']),
      pomodoroRemaining:
          serializer.fromJson<Duration?>(json['pomodoro_remaining']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'created_at': serializer.toJson<DateTime>(createdAt),
      'modified_at': serializer.toJson<DateTime>(modifiedAt),
      'context_id': serializer.toJson<Uuid?>(contextId),
      'start': serializer.toJson<DateTime>(start),
      'end': serializer.toJson<DateTime>(end),
      'priority': serializer.toJson<int>(priority),
      'pomodoro': serializer.toJson<Duration?>(pomodoro),
      'pomodoro_remaining': serializer.toJson<Duration?>(pomodoroRemaining),
    };
  }

  SessionRow copyWith(
          {int? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          Value<Uuid?> contextId = const Value.absent(),
          DateTime? start,
          DateTime? end,
          int? priority,
          Value<Duration?> pomodoro = const Value.absent(),
          Value<Duration?> pomodoroRemaining = const Value.absent()}) =>
      SessionRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        contextId: contextId.present ? contextId.value : this.contextId,
        start: start ?? this.start,
        end: end ?? this.end,
        priority: priority ?? this.priority,
        pomodoro: pomodoro.present ? pomodoro.value : this.pomodoro,
        pomodoroRemaining: pomodoroRemaining.present
            ? pomodoroRemaining.value
            : this.pomodoroRemaining,
      );
  SessionRow copyWithCompanion(SessionsCompanion data) {
    return SessionRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      modifiedAt:
          data.modifiedAt.present ? data.modifiedAt.value : this.modifiedAt,
      contextId: data.contextId.present ? data.contextId.value : this.contextId,
      start: data.start.present ? data.start.value : this.start,
      end: data.end.present ? data.end.value : this.end,
      priority: data.priority.present ? data.priority.value : this.priority,
      pomodoro: data.pomodoro.present ? data.pomodoro.value : this.pomodoro,
      pomodoroRemaining: data.pomodoroRemaining.present
          ? data.pomodoroRemaining.value
          : this.pomodoroRemaining,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SessionRow(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('contextId: $contextId, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('priority: $priority, ')
          ..write('pomodoro: $pomodoro, ')
          ..write('pomodoroRemaining: $pomodoroRemaining')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, createdAt, modifiedAt, contextId, start,
      end, priority, pomodoro, pomodoroRemaining);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SessionRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.contextId == this.contextId &&
          other.start == this.start &&
          other.end == this.end &&
          other.priority == this.priority &&
          other.pomodoro == this.pomodoro &&
          other.pomodoroRemaining == this.pomodoroRemaining);
}

class SessionsCompanion extends UpdateCompanion<SessionRow> {
  final Value<int> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<Uuid?> contextId;
  final Value<DateTime> start;
  final Value<DateTime> end;
  final Value<int> priority;
  final Value<Duration?> pomodoro;
  final Value<Duration?> pomodoroRemaining;
  const SessionsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.contextId = const Value.absent(),
    this.start = const Value.absent(),
    this.end = const Value.absent(),
    this.priority = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.pomodoroRemaining = const Value.absent(),
  });
  SessionsCompanion.insert({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.contextId = const Value.absent(),
    required DateTime start,
    required DateTime end,
    this.priority = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.pomodoroRemaining = const Value.absent(),
  })  : start = Value(start),
        end = Value(end);
  static Insertable<SessionRow> custom({
    Expression<int>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<Uint8List>? contextId,
    Expression<DateTime>? start,
    Expression<DateTime>? end,
    Expression<int>? priority,
    Expression<int>? pomodoro,
    Expression<int>? pomodoroRemaining,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (contextId != null) 'context_id': contextId,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
      if (priority != null) 'priority': priority,
      if (pomodoro != null) 'pomodoro': pomodoro,
      if (pomodoroRemaining != null) 'pomodoro_remaining': pomodoroRemaining,
    });
  }

  SessionsCompanion copyWith(
      {Value<int>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<Uuid?>? contextId,
      Value<DateTime>? start,
      Value<DateTime>? end,
      Value<int>? priority,
      Value<Duration?>? pomodoro,
      Value<Duration?>? pomodoroRemaining}) {
    return SessionsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      contextId: contextId ?? this.contextId,
      start: start ?? this.start,
      end: end ?? this.end,
      priority: priority ?? this.priority,
      pomodoro: pomodoro ?? this.pomodoro,
      pomodoroRemaining: pomodoroRemaining ?? this.pomodoroRemaining,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (contextId.present) {
      map['context_id'] = Variable<Uint8List>(
          $SessionsTable.$convertercontextIdn.toSql(contextId.value));
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
    if (pomodoroRemaining.present) {
      map['pomodoro_remaining'] = Variable<int>($SessionsTable
          .$converterpomodoroRemainingn
          .toSql(pomodoroRemaining.value));
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SessionsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('contextId: $contextId, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('priority: $priority, ')
          ..write('pomodoro: $pomodoro, ')
          ..write('pomodoroRemaining: $pomodoroRemaining')
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
  late final $ContextsTable contexts = $ContextsTable(this);
  late final $NotesTable notes = $NotesTable(this);
  late final $EventsTable events = $EventsTable(this);
  late final $BudgetsTable budgets = $BudgetsTable(this);
  late final $SessionsTable sessions = $SessionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        syncStates,
        accounts,
        calendars,
        contexts,
        notes,
        events,
        budgets,
        sessions
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
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  required String email,
  required AccountProvider provider,
});
typedef $$AccountsTableUpdateCompanionBuilder = AccountsCompanion Function({
  Value<int> id,
  Value<DateTime> createdAt,
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

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String> email = const Value.absent(),
            Value<AccountProvider> provider = const Value.absent(),
          }) =>
              AccountsCompanion(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            email: email,
            provider: provider,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            required String email,
            required AccountProvider provider,
          }) =>
              AccountsCompanion.insert(
            id: id,
            createdAt: createdAt,
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
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  required String name,
  required bool enabled,
  required int accountId,
});
typedef $$CalendarsTableUpdateCompanionBuilder = CalendarsCompanion Function({
  Value<int> id,
  Value<DateTime> createdAt,
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

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<bool> enabled = const Value.absent(),
            Value<int> accountId = const Value.absent(),
          }) =>
              CalendarsCompanion(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            name: name,
            enabled: enabled,
            accountId: accountId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            required String name,
            required bool enabled,
            required int accountId,
          }) =>
              CalendarsCompanion.insert(
            id: id,
            createdAt: createdAt,
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
typedef $$ContextsTableCreateCompanionBuilder = ContextsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  required String name,
  required Path path,
  Value<Order> order,
  Value<Duration> pomodoro,
  Value<int> rowid,
});
typedef $$ContextsTableUpdateCompanionBuilder = ContextsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<String> name,
  Value<Path> path,
  Value<Order> order,
  Value<Duration> pomodoro,
  Value<int> rowid,
});

final class $$ContextsTableReferences
    extends BaseReferences<_$Store, $ContextsTable, ContextRow> {
  $$ContextsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$NotesTable, List<NoteRow>> _notesRefsTable(
          _$Store db) =>
      MultiTypedResultKey.fromTable(db.notes,
          aliasName: $_aliasNameGenerator(db.contexts.id, db.notes.contextId));

  $$NotesTableProcessedTableManager get notesRefs {
    final manager = $$NotesTableTableManager($_db, $_db.notes)
        .filter((f) => f.contextId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_notesRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$EventsTable, List<EventRow>> _eventsRefsTable(
          _$Store db) =>
      MultiTypedResultKey.fromTable(db.events,
          aliasName: $_aliasNameGenerator(db.contexts.id, db.events.contextId));

  $$EventsTableProcessedTableManager get eventsRefs {
    final manager = $$EventsTableTableManager($_db, $_db.events)
        .filter((f) => f.contextId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_eventsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$BudgetsTable, List<BudgetRow>> _budgetsRefsTable(
          _$Store db) =>
      MultiTypedResultKey.fromTable(db.budgets,
          aliasName:
              $_aliasNameGenerator(db.contexts.id, db.budgets.contextId));

  $$BudgetsTableProcessedTableManager get budgetsRefs {
    final manager = $$BudgetsTableTableManager($_db, $_db.budgets)
        .filter((f) => f.contextId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_budgetsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }

  static MultiTypedResultKey<$SessionsTable, List<SessionRow>>
      _sessionsRefsTable(_$Store db) =>
          MultiTypedResultKey.fromTable(db.sessions,
              aliasName:
                  $_aliasNameGenerator(db.contexts.id, db.sessions.contextId));

  $$SessionsTableProcessedTableManager get sessionsRefs {
    final manager = $$SessionsTableTableManager($_db, $_db.sessions)
        .filter((f) => f.contextId.id($_item.id));

    final cache = $_typedResult.readTableOrNull(_sessionsRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$ContextsTableFilterComposer
    extends FilterComposer<_$Store, $ContextsTable> {
  $$ContextsTableFilterComposer(super.$state);
  ColumnWithTypeConverterFilters<Uuid, Uuid, Uint8List> get id =>
      $state.composableBuilder(
          column: $state.table.id,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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
        getReferencedColumn: (t) => t.contextId,
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
        getReferencedColumn: (t) => t.contextId,
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
        getReferencedColumn: (t) => t.contextId,
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
        getReferencedColumn: (t) => t.contextId,
        builder: (joinBuilder, parentComposers) =>
            $$SessionsTableFilterComposer(ComposerState(
                $state.db, $state.db.sessions, joinBuilder, parentComposers)));
    return f(composer);
  }
}

class $$ContextsTableOrderingComposer
    extends OrderingComposer<_$Store, $ContextsTable> {
  $$ContextsTableOrderingComposer(super.$state);
  ColumnOrderings<Uint8List> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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

class $$ContextsTableTableManager extends RootTableManager<
    _$Store,
    $ContextsTable,
    ContextRow,
    $$ContextsTableFilterComposer,
    $$ContextsTableOrderingComposer,
    $$ContextsTableCreateCompanionBuilder,
    $$ContextsTableUpdateCompanionBuilder,
    (ContextRow, $$ContextsTableReferences),
    ContextRow,
    PrefetchHooks Function(
        {bool notesRefs,
        bool eventsRefs,
        bool budgetsRefs,
        bool sessionsRefs})> {
  $$ContextsTableTableManager(_$Store db, $ContextsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$ContextsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$ContextsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<Path> path = const Value.absent(),
            Value<Order> order = const Value.absent(),
            Value<Duration> pomodoro = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ContextsCompanion(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            name: name,
            path: path,
            order: order,
            pomodoro: pomodoro,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            required String name,
            required Path path,
            Value<Order> order = const Value.absent(),
            Value<Duration> pomodoro = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              ContextsCompanion.insert(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            name: name,
            path: path,
            order: order,
            pomodoro: pomodoro,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$ContextsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: (
              {notesRefs = false,
              eventsRefs = false,
              budgetsRefs = false,
              sessionsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (notesRefs) db.notes,
                if (eventsRefs) db.events,
                if (budgetsRefs) db.budgets,
                if (sessionsRefs) db.sessions
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (notesRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ContextsTableReferences._notesRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ContextsTableReferences(db, table, p0).notesRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.contextId == item.id),
                        typedResults: items),
                  if (eventsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ContextsTableReferences._eventsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ContextsTableReferences(db, table, p0).eventsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.contextId == item.id),
                        typedResults: items),
                  if (budgetsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ContextsTableReferences._budgetsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ContextsTableReferences(db, table, p0)
                                .budgetsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.contextId == item.id),
                        typedResults: items),
                  if (sessionsRefs)
                    await $_getPrefetchedData(
                        currentTable: table,
                        referencedTable:
                            $$ContextsTableReferences._sessionsRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$ContextsTableReferences(db, table, p0)
                                .sessionsRefs,
                        referencedItemsForCurrentItem:
                            (item, referencedItems) => referencedItems
                                .where((e) => e.contextId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$ContextsTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $ContextsTable,
    ContextRow,
    $$ContextsTableFilterComposer,
    $$ContextsTableOrderingComposer,
    $$ContextsTableCreateCompanionBuilder,
    $$ContextsTableUpdateCompanionBuilder,
    (ContextRow, $$ContextsTableReferences),
    ContextRow,
    PrefetchHooks Function(
        {bool notesRefs,
        bool eventsRefs,
        bool budgetsRefs,
        bool sessionsRefs})>;
typedef $$NotesTableCreateCompanionBuilder = NotesCompanion Function({
  Value<Uuid> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<Uuid> userId,
  required String body,
  Value<Order> order,
  Value<bool> root,
  Value<bool> private,
  required Uuid topicId,
  Value<Uuid?> contextId,
  Value<int> rowid,
});
typedef $$NotesTableUpdateCompanionBuilder = NotesCompanion Function({
  Value<Uuid> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<Uuid> userId,
  Value<String> body,
  Value<Order> order,
  Value<bool> root,
  Value<bool> private,
  Value<Uuid> topicId,
  Value<Uuid?> contextId,
  Value<int> rowid,
});

final class $$NotesTableReferences
    extends BaseReferences<_$Store, $NotesTable, NoteRow> {
  $$NotesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ContextsTable _contextIdTable(_$Store db) => db.contexts
      .createAlias($_aliasNameGenerator(db.notes.contextId, db.contexts.id));

  $$ContextsTableProcessedTableManager? get contextId {
    if ($_item.contextId == null) return null;
    final manager = $$ContextsTableTableManager($_db, $_db.contexts)
        .filter((f) => f.id($_item.contextId!));
    final item = $_typedResult.readTableOrNull(_contextIdTable($_db));
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

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
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

  ColumnFilters<bool> get root => $state.composableBuilder(
      column: $state.table.root,
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

  $$ContextsTableFilterComposer get contextId {
    final $$ContextsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableFilterComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
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

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
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

  ColumnOrderings<bool> get root => $state.composableBuilder(
      column: $state.table.root,
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

  $$ContextsTableOrderingComposer get contextId {
    final $$ContextsTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableOrderingComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
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
    PrefetchHooks Function({bool contextId})> {
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
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid> userId = const Value.absent(),
            Value<String> body = const Value.absent(),
            Value<Order> order = const Value.absent(),
            Value<bool> root = const Value.absent(),
            Value<bool> private = const Value.absent(),
            Value<Uuid> topicId = const Value.absent(),
            Value<Uuid?> contextId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              NotesCompanion(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            userId: userId,
            body: body,
            order: order,
            root: root,
            private: private,
            topicId: topicId,
            contextId: contextId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid> userId = const Value.absent(),
            required String body,
            Value<Order> order = const Value.absent(),
            Value<bool> root = const Value.absent(),
            Value<bool> private = const Value.absent(),
            required Uuid topicId,
            Value<Uuid?> contextId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              NotesCompanion.insert(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            userId: userId,
            body: body,
            order: order,
            root: root,
            private: private,
            topicId: topicId,
            contextId: contextId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$NotesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({contextId = false}) {
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
                if (contextId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.contextId,
                    referencedTable: $$NotesTableReferences._contextIdTable(db),
                    referencedColumn:
                        $$NotesTableReferences._contextIdTable(db).id,
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
    PrefetchHooks Function({bool contextId})>;
typedef $$EventsTableCreateCompanionBuilder = EventsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<String?> name,
  required DateTime start,
  required DateTime end,
  Value<String?> series,
  required EventResponse response,
  Value<Uuid?> contextId,
  Value<int> rowid,
});
typedef $$EventsTableUpdateCompanionBuilder = EventsCompanion Function({
  Value<Uuid> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<String?> name,
  Value<DateTime> start,
  Value<DateTime> end,
  Value<String?> series,
  Value<EventResponse> response,
  Value<Uuid?> contextId,
  Value<int> rowid,
});

final class $$EventsTableReferences
    extends BaseReferences<_$Store, $EventsTable, EventRow> {
  $$EventsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ContextsTable _contextIdTable(_$Store db) => db.contexts
      .createAlias($_aliasNameGenerator(db.events.contextId, db.contexts.id));

  $$ContextsTableProcessedTableManager? get contextId {
    if ($_item.contextId == null) return null;
    final manager = $$ContextsTableTableManager($_db, $_db.contexts)
        .filter((f) => f.id($_item.contextId!));
    final item = $_typedResult.readTableOrNull(_contextIdTable($_db));
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

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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

  $$ContextsTableFilterComposer get contextId {
    final $$ContextsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableFilterComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
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

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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

  $$ContextsTableOrderingComposer get contextId {
    final $$ContextsTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableOrderingComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
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
    PrefetchHooks Function({bool contextId})> {
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
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String?> name = const Value.absent(),
            Value<DateTime> start = const Value.absent(),
            Value<DateTime> end = const Value.absent(),
            Value<String?> series = const Value.absent(),
            Value<EventResponse> response = const Value.absent(),
            Value<Uuid?> contextId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              EventsCompanion(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            name: name,
            start: start,
            end: end,
            series: series,
            response: response,
            contextId: contextId,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            Value<Uuid> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String?> name = const Value.absent(),
            required DateTime start,
            required DateTime end,
            Value<String?> series = const Value.absent(),
            required EventResponse response,
            Value<Uuid?> contextId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              EventsCompanion.insert(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            name: name,
            start: start,
            end: end,
            series: series,
            response: response,
            contextId: contextId,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$EventsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({contextId = false}) {
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
                if (contextId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.contextId,
                    referencedTable:
                        $$EventsTableReferences._contextIdTable(db),
                    referencedColumn:
                        $$EventsTableReferences._contextIdTable(db).id,
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
    PrefetchHooks Function({bool contextId})>;
typedef $$BudgetsTableCreateCompanionBuilder = BudgetsCompanion Function({
  Value<int> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<Uuid?> contextId,
});
typedef $$BudgetsTableUpdateCompanionBuilder = BudgetsCompanion Function({
  Value<int> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<Uuid?> contextId,
});

final class $$BudgetsTableReferences
    extends BaseReferences<_$Store, $BudgetsTable, BudgetRow> {
  $$BudgetsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ContextsTable _contextIdTable(_$Store db) => db.contexts
      .createAlias($_aliasNameGenerator(db.budgets.contextId, db.contexts.id));

  $$ContextsTableProcessedTableManager? get contextId {
    if ($_item.contextId == null) return null;
    final manager = $$ContextsTableTableManager($_db, $_db.contexts)
        .filter((f) => f.id($_item.contextId!));
    final item = $_typedResult.readTableOrNull(_contextIdTable($_db));
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

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  $$ContextsTableFilterComposer get contextId {
    final $$ContextsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableFilterComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
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

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get modifiedAt => $state.composableBuilder(
      column: $state.table.modifiedAt,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ContextsTableOrderingComposer get contextId {
    final $$ContextsTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableOrderingComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
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
    PrefetchHooks Function({bool contextId})> {
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
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> contextId = const Value.absent(),
          }) =>
              BudgetsCompanion(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            contextId: contextId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> contextId = const Value.absent(),
          }) =>
              BudgetsCompanion.insert(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            contextId: contextId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$BudgetsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({contextId = false}) {
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
                if (contextId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.contextId,
                    referencedTable:
                        $$BudgetsTableReferences._contextIdTable(db),
                    referencedColumn:
                        $$BudgetsTableReferences._contextIdTable(db).id,
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
    PrefetchHooks Function({bool contextId})>;
typedef $$SessionsTableCreateCompanionBuilder = SessionsCompanion Function({
  Value<int> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<Uuid?> contextId,
  required DateTime start,
  required DateTime end,
  Value<int> priority,
  Value<Duration?> pomodoro,
  Value<Duration?> pomodoroRemaining,
});
typedef $$SessionsTableUpdateCompanionBuilder = SessionsCompanion Function({
  Value<int> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<Uuid?> contextId,
  Value<DateTime> start,
  Value<DateTime> end,
  Value<int> priority,
  Value<Duration?> pomodoro,
  Value<Duration?> pomodoroRemaining,
});

final class $$SessionsTableReferences
    extends BaseReferences<_$Store, $SessionsTable, SessionRow> {
  $$SessionsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ContextsTable _contextIdTable(_$Store db) => db.contexts
      .createAlias($_aliasNameGenerator(db.sessions.contextId, db.contexts.id));

  $$ContextsTableProcessedTableManager? get contextId {
    if ($_item.contextId == null) return null;
    final manager = $$ContextsTableTableManager($_db, $_db.contexts)
        .filter((f) => f.id($_item.contextId!));
    final item = $_typedResult.readTableOrNull(_contextIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$SessionsTableFilterComposer
    extends FilterComposer<_$Store, $SessionsTable> {
  $$SessionsTableFilterComposer(super.$state);
  ColumnFilters<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

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

  ColumnWithTypeConverterFilters<Duration?, Duration, int>
      get pomodoroRemaining => $state.composableBuilder(
          column: $state.table.pomodoroRemaining,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));

  $$ContextsTableFilterComposer get contextId {
    final $$ContextsTableFilterComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableFilterComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
    return composer;
  }
}

class $$SessionsTableOrderingComposer
    extends OrderingComposer<_$Store, $SessionsTable> {
  $$SessionsTableOrderingComposer(super.$state);
  ColumnOrderings<int> get id => $state.composableBuilder(
      column: $state.table.id,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  ColumnOrderings<DateTime> get createdAt => $state.composableBuilder(
      column: $state.table.createdAt,
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

  ColumnOrderings<int> get pomodoroRemaining => $state.composableBuilder(
      column: $state.table.pomodoroRemaining,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));

  $$ContextsTableOrderingComposer get contextId {
    final $$ContextsTableOrderingComposer composer = $state.composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.contextId,
        referencedTable: $state.db.contexts,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder, parentComposers) =>
            $$ContextsTableOrderingComposer(ComposerState(
                $state.db, $state.db.contexts, joinBuilder, parentComposers)));
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
    PrefetchHooks Function({bool contextId})> {
  $$SessionsTableTableManager(_$Store db, $SessionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$SessionsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$SessionsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> contextId = const Value.absent(),
            Value<DateTime> start = const Value.absent(),
            Value<DateTime> end = const Value.absent(),
            Value<int> priority = const Value.absent(),
            Value<Duration?> pomodoro = const Value.absent(),
            Value<Duration?> pomodoroRemaining = const Value.absent(),
          }) =>
              SessionsCompanion(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            contextId: contextId,
            start: start,
            end: end,
            priority: priority,
            pomodoro: pomodoro,
            pomodoroRemaining: pomodoroRemaining,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uuid?> contextId = const Value.absent(),
            required DateTime start,
            required DateTime end,
            Value<int> priority = const Value.absent(),
            Value<Duration?> pomodoro = const Value.absent(),
            Value<Duration?> pomodoroRemaining = const Value.absent(),
          }) =>
              SessionsCompanion.insert(
            id: id,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            contextId: contextId,
            start: start,
            end: end,
            priority: priority,
            pomodoro: pomodoro,
            pomodoroRemaining: pomodoroRemaining,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$SessionsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({contextId = false}) {
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
                if (contextId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.contextId,
                    referencedTable:
                        $$SessionsTableReferences._contextIdTable(db),
                    referencedColumn:
                        $$SessionsTableReferences._contextIdTable(db).id,
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
    PrefetchHooks Function({bool contextId})>;

class $StoreManager {
  final _$Store _db;
  $StoreManager(this._db);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db, _db.accounts);
  $$CalendarsTableTableManager get calendars =>
      $$CalendarsTableTableManager(_db, _db.calendars);
  $$ContextsTableTableManager get contexts =>
      $$ContextsTableTableManager(_db, _db.contexts);
  $$NotesTableTableManager get notes =>
      $$NotesTableTableManager(_db, _db.notes);
  $$EventsTableTableManager get events =>
      $$EventsTableTableManager(_db, _db.events);
  $$BudgetsTableTableManager get budgets =>
      $$BudgetsTableTableManager(_db, _db.budgets);
  $$SessionsTableTableManager get sessions =>
      $$SessionsTableTableManager(_db, _db.sessions);
}
