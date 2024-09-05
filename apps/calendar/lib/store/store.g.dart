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
      pushedAt: serializer.fromJson<DateTime?>(json['pushedAt']),
      lastPulled: serializer.fromJson<String?>(json['lastPulled']),
      more: serializer.fromJson<bool>(json['more']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entity': serializer.toJson<String>(entity),
      'pushedAt': serializer.toJson<DateTime?>(pushedAt),
      'lastPulled': serializer.toJson<String?>(lastPulled),
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

class $AccountsTable extends Accounts with TableInfo<$AccountsTable, Account> {
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
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
      'email', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _providerMeta =
      const VerificationMeta('provider');
  @override
  late final GeneratedColumnWithTypeConverter<AccountProvider, int> provider =
      GeneratedColumn<int>('provider', aliasedName, false,
              type: DriftSqlType.int, requiredDuringInsert: true)
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
  VerificationContext validateIntegrity(Insertable<Account> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    } else if (isInserting) {
      context.missing(_modifiedAtMeta);
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
  Account map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Account(
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
          .read(DriftSqlType.int, data['${effectivePrefix}provider'])!),
    );
  }

  @override
  $AccountsTable createAlias(String alias) {
    return $AccountsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<AccountProvider, int, int> $converterprovider =
      const EnumIndexConverter<AccountProvider>(AccountProvider.values);
}

class Account extends DataClass implements Insertable<Account> {
  final int id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String email;
  final AccountProvider provider;
  const Account(
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
          Variable<int>($AccountsTable.$converterprovider.toSql(provider));
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

  factory Account.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Account(
      id: serializer.fromJson<int>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      modifiedAt: serializer.fromJson<DateTime>(json['modifiedAt']),
      email: serializer.fromJson<String>(json['email']),
      provider: $AccountsTable.$converterprovider
          .fromJson(serializer.fromJson<int>(json['provider'])),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'modifiedAt': serializer.toJson<DateTime>(modifiedAt),
      'email': serializer.toJson<String>(email),
      'provider': serializer
          .toJson<int>($AccountsTable.$converterprovider.toJson(provider)),
    };
  }

  Account copyWith(
          {int? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          String? email,
          AccountProvider? provider}) =>
      Account(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        email: email ?? this.email,
        provider: provider ?? this.provider,
      );
  Account copyWithCompanion(AccountsCompanion data) {
    return Account(
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
    return (StringBuffer('Account(')
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
      (other is Account &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.email == this.email &&
          other.provider == this.provider);
}

class AccountsCompanion extends UpdateCompanion<Account> {
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
    required DateTime createdAt,
    required DateTime modifiedAt,
    required String email,
    required AccountProvider provider,
  })  : createdAt = Value(createdAt),
        modifiedAt = Value(modifiedAt),
        email = Value(email),
        provider = Value(provider);
  static Insertable<Account> custom({
    Expression<int>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? modifiedAt,
    Expression<String>? email,
    Expression<int>? provider,
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
      map['provider'] = Variable<int>(
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

class $ContextsTable extends Contexts with TableInfo<$ContextsTable, Context> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ContextsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<Uint8List> id = GeneratedColumn<Uint8List>(
      'id', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orderMeta = const VerificationMeta('order');
  @override
  late final GeneratedColumnWithTypeConverter<Order, double> order =
      GeneratedColumn<double>('order', aliasedName, false,
              type: DriftSqlType.double,
              requiredDuringInsert: false,
              clientDefault: () => Order().toDouble())
          .withConverter<Order>($ContextsTable.$converterorder);
  static const VerificationMeta _pomodoroMeta =
      const VerificationMeta('pomodoro');
  @override
  late final GeneratedColumnWithTypeConverter<Duration, int> pomodoro =
      GeneratedColumn<int>('pomodoro', aliasedName, false,
              type: DriftSqlType.int,
              requiredDuringInsert: false,
              defaultValue: const Constant(25))
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
  VerificationContext validateIntegrity(Insertable<Context> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    } else if (isInserting) {
      context.missing(_modifiedAtMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    context.handle(_orderMeta, const VerificationResult.success());
    context.handle(_pomodoroMeta, const VerificationResult.success());
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Context map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Context(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}id'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
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

  static TypeConverter<Order, double> $converterorder = const OrderConverter();
  static TypeConverter<Duration, int> $converterpomodoro =
      const MinutesConverter();
}

class Context extends DataClass implements Insertable<Context> {
  final Uint8List id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String name;
  final String path;
  final Order order;
  final Duration pomodoro;
  const Context(
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
    map['id'] = Variable<Uint8List>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['name'] = Variable<String>(name);
    map['path'] = Variable<String>(path);
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

  factory Context.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Context(
      id: serializer.fromJson<Uint8List>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      modifiedAt: serializer.fromJson<DateTime>(json['modifiedAt']),
      name: serializer.fromJson<String>(json['name']),
      path: serializer.fromJson<String>(json['path']),
      order: serializer.fromJson<Order>(json['order']),
      pomodoro: serializer.fromJson<Duration>(json['pomodoro']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uint8List>(id),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'modifiedAt': serializer.toJson<DateTime>(modifiedAt),
      'name': serializer.toJson<String>(name),
      'path': serializer.toJson<String>(path),
      'order': serializer.toJson<Order>(order),
      'pomodoro': serializer.toJson<Duration>(pomodoro),
    };
  }

  Context copyWith(
          {Uint8List? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          String? name,
          String? path,
          Order? order,
          Duration? pomodoro}) =>
      Context(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
        name: name ?? this.name,
        path: path ?? this.path,
        order: order ?? this.order,
        pomodoro: pomodoro ?? this.pomodoro,
      );
  Context copyWithCompanion(ContextsCompanion data) {
    return Context(
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
    return (StringBuffer('Context(')
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
  int get hashCode => Object.hash($driftBlobEquality.hash(id), createdAt,
      modifiedAt, name, path, order, pomodoro);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Context &&
          $driftBlobEquality.equals(other.id, this.id) &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          other.name == this.name &&
          other.path == this.path &&
          other.order == this.order &&
          other.pomodoro == this.pomodoro);
}

class ContextsCompanion extends UpdateCompanion<Context> {
  final Value<Uint8List> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<String> name;
  final Value<String> path;
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
    required Uint8List id,
    required DateTime createdAt,
    required DateTime modifiedAt,
    required String name,
    required String path,
    this.order = const Value.absent(),
    this.pomodoro = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        createdAt = Value(createdAt),
        modifiedAt = Value(modifiedAt),
        name = Value(name),
        path = Value(path);
  static Insertable<Context> custom({
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
      {Value<Uint8List>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<String>? name,
      Value<String>? path,
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
      map['id'] = Variable<Uint8List>(id.value);
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
      map['path'] = Variable<String>(path.value);
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

class $NotesTable extends Notes with TableInfo<$NotesTable, Note> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<Uint8List> id = GeneratedColumn<Uint8List>(
      'id', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _modifiedAtMeta =
      const VerificationMeta('modifiedAt');
  @override
  late final GeneratedColumn<DateTime> modifiedAt = GeneratedColumn<DateTime>(
      'modified_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<Uint8List> userId = GeneratedColumn<Uint8List>(
      'user_id', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
      'body', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _orderMeta = const VerificationMeta('order');
  @override
  late final GeneratedColumn<double> order = GeneratedColumn<double>(
      'order', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _rootMeta = const VerificationMeta('root');
  @override
  late final GeneratedColumn<bool> root = GeneratedColumn<bool>(
      'root', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("root" IN (0, 1))'));
  static const VerificationMeta _privateMeta =
      const VerificationMeta('private');
  @override
  late final GeneratedColumn<bool> private = GeneratedColumn<bool>(
      'private', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("private" IN (0, 1))'));
  static const VerificationMeta _topicIdMeta =
      const VerificationMeta('topicId');
  @override
  late final GeneratedColumn<Uint8List> topicId = GeneratedColumn<Uint8List>(
      'topic_id', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _contextIdMeta =
      const VerificationMeta('contextId');
  @override
  late final GeneratedColumn<Uint8List> contextId = GeneratedColumn<Uint8List>(
      'context_id', aliasedName, true,
      type: DriftSqlType.blob,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('REFERENCES contexts (id)'));
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
  VerificationContext validateIntegrity(Insertable<Note> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('modified_at')) {
      context.handle(
          _modifiedAtMeta,
          modifiedAt.isAcceptableOrUnknown(
              data['modified_at']!, _modifiedAtMeta));
    } else if (isInserting) {
      context.missing(_modifiedAtMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(_userIdMeta,
          userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta));
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
          _bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('order')) {
      context.handle(
          _orderMeta, order.isAcceptableOrUnknown(data['order']!, _orderMeta));
    } else if (isInserting) {
      context.missing(_orderMeta);
    }
    if (data.containsKey('root')) {
      context.handle(
          _rootMeta, root.isAcceptableOrUnknown(data['root']!, _rootMeta));
    } else if (isInserting) {
      context.missing(_rootMeta);
    }
    if (data.containsKey('private')) {
      context.handle(_privateMeta,
          private.isAcceptableOrUnknown(data['private']!, _privateMeta));
    } else if (isInserting) {
      context.missing(_privateMeta);
    }
    if (data.containsKey('topic_id')) {
      context.handle(_topicIdMeta,
          topicId.isAcceptableOrUnknown(data['topic_id']!, _topicIdMeta));
    } else if (isInserting) {
      context.missing(_topicIdMeta);
    }
    if (data.containsKey('context_id')) {
      context.handle(_contextIdMeta,
          contextId.isAcceptableOrUnknown(data['context_id']!, _contextIdMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Note map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Note(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}id'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      modifiedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}modified_at'])!,
      userId: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}user_id'])!,
      body: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}body'])!,
      order: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}order'])!,
      root: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}root'])!,
      private: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}private'])!,
      topicId: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}topic_id'])!,
      contextId: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}context_id']),
    );
  }

  @override
  $NotesTable createAlias(String alias) {
    return $NotesTable(attachedDatabase, alias);
  }
}

class Note extends DataClass implements Insertable<Note> {
  final Uint8List id;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final Uint8List userId;
  final String body;
  final double order;
  final bool root;
  final bool private;
  final Uint8List topicId;
  final Uint8List? contextId;
  const Note(
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
    map['id'] = Variable<Uint8List>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['modified_at'] = Variable<DateTime>(modifiedAt);
    map['user_id'] = Variable<Uint8List>(userId);
    map['body'] = Variable<String>(body);
    map['order'] = Variable<double>(order);
    map['root'] = Variable<bool>(root);
    map['private'] = Variable<bool>(private);
    map['topic_id'] = Variable<Uint8List>(topicId);
    if (!nullToAbsent || contextId != null) {
      map['context_id'] = Variable<Uint8List>(contextId);
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

  factory Note.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Note(
      id: serializer.fromJson<Uint8List>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      modifiedAt: serializer.fromJson<DateTime>(json['modifiedAt']),
      userId: serializer.fromJson<Uint8List>(json['userId']),
      body: serializer.fromJson<String>(json['body']),
      order: serializer.fromJson<double>(json['order']),
      root: serializer.fromJson<bool>(json['root']),
      private: serializer.fromJson<bool>(json['private']),
      topicId: serializer.fromJson<Uint8List>(json['topicId']),
      contextId: serializer.fromJson<Uint8List?>(json['contextId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<Uint8List>(id),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'modifiedAt': serializer.toJson<DateTime>(modifiedAt),
      'userId': serializer.toJson<Uint8List>(userId),
      'body': serializer.toJson<String>(body),
      'order': serializer.toJson<double>(order),
      'root': serializer.toJson<bool>(root),
      'private': serializer.toJson<bool>(private),
      'topicId': serializer.toJson<Uint8List>(topicId),
      'contextId': serializer.toJson<Uint8List?>(contextId),
    };
  }

  Note copyWith(
          {Uint8List? id,
          DateTime? createdAt,
          DateTime? modifiedAt,
          Uint8List? userId,
          String? body,
          double? order,
          bool? root,
          bool? private,
          Uint8List? topicId,
          Value<Uint8List?> contextId = const Value.absent()}) =>
      Note(
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
  Note copyWithCompanion(NotesCompanion data) {
    return Note(
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
    return (StringBuffer('Note(')
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
  int get hashCode => Object.hash(
      $driftBlobEquality.hash(id),
      createdAt,
      modifiedAt,
      $driftBlobEquality.hash(userId),
      body,
      order,
      root,
      private,
      $driftBlobEquality.hash(topicId),
      $driftBlobEquality.hash(contextId));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Note &&
          $driftBlobEquality.equals(other.id, this.id) &&
          other.createdAt == this.createdAt &&
          other.modifiedAt == this.modifiedAt &&
          $driftBlobEquality.equals(other.userId, this.userId) &&
          other.body == this.body &&
          other.order == this.order &&
          other.root == this.root &&
          other.private == this.private &&
          $driftBlobEquality.equals(other.topicId, this.topicId) &&
          $driftBlobEquality.equals(other.contextId, this.contextId));
}

class NotesCompanion extends UpdateCompanion<Note> {
  final Value<Uint8List> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> modifiedAt;
  final Value<Uint8List> userId;
  final Value<String> body;
  final Value<double> order;
  final Value<bool> root;
  final Value<bool> private;
  final Value<Uint8List> topicId;
  final Value<Uint8List?> contextId;
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
    required Uint8List id,
    required DateTime createdAt,
    required DateTime modifiedAt,
    required Uint8List userId,
    required String body,
    required double order,
    required bool root,
    required bool private,
    required Uint8List topicId,
    this.contextId = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        createdAt = Value(createdAt),
        modifiedAt = Value(modifiedAt),
        userId = Value(userId),
        body = Value(body),
        order = Value(order),
        root = Value(root),
        private = Value(private),
        topicId = Value(topicId);
  static Insertable<Note> custom({
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
      {Value<Uint8List>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? modifiedAt,
      Value<Uint8List>? userId,
      Value<String>? body,
      Value<double>? order,
      Value<bool>? root,
      Value<bool>? private,
      Value<Uint8List>? topicId,
      Value<Uint8List?>? contextId,
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
      map['id'] = Variable<Uint8List>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<DateTime>(modifiedAt.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<Uint8List>(userId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (order.present) {
      map['order'] = Variable<double>(order.value);
    }
    if (root.present) {
      map['root'] = Variable<bool>(root.value);
    }
    if (private.present) {
      map['private'] = Variable<bool>(private.value);
    }
    if (topicId.present) {
      map['topic_id'] = Variable<Uint8List>(topicId.value);
    }
    if (contextId.present) {
      map['context_id'] = Variable<Uint8List>(contextId.value);
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

abstract class _$Store extends GeneratedDatabase {
  _$Store(QueryExecutor e) : super(e);
  $StoreManager get managers => $StoreManager(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $AccountsTable accounts = $AccountsTable(this);
  late final $ContextsTable contexts = $ContextsTable(this);
  late final $NotesTable notes = $NotesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [syncStates, accounts, contexts, notes];
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
  required DateTime createdAt,
  required DateTime modifiedAt,
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

  ColumnWithTypeConverterFilters<AccountProvider, AccountProvider, int>
      get provider => $state.composableBuilder(
          column: $state.table.provider,
          builder: (column, joinBuilders) => ColumnWithTypeConverterFilters(
              column,
              joinBuilders: joinBuilders));
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

  ColumnOrderings<int> get provider => $state.composableBuilder(
      column: $state.table.provider,
      builder: (column, joinBuilders) =>
          ColumnOrderings(column, joinBuilders: joinBuilders));
}

class $$AccountsTableTableManager extends RootTableManager<
    _$Store,
    $AccountsTable,
    Account,
    $$AccountsTableFilterComposer,
    $$AccountsTableOrderingComposer,
    $$AccountsTableCreateCompanionBuilder,
    $$AccountsTableUpdateCompanionBuilder,
    (Account, BaseReferences<_$Store, $AccountsTable, Account>),
    Account,
    PrefetchHooks Function()> {
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
            required DateTime createdAt,
            required DateTime modifiedAt,
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
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$AccountsTableProcessedTableManager = ProcessedTableManager<
    _$Store,
    $AccountsTable,
    Account,
    $$AccountsTableFilterComposer,
    $$AccountsTableOrderingComposer,
    $$AccountsTableCreateCompanionBuilder,
    $$AccountsTableUpdateCompanionBuilder,
    (Account, BaseReferences<_$Store, $AccountsTable, Account>),
    Account,
    PrefetchHooks Function()>;
typedef $$ContextsTableCreateCompanionBuilder = ContextsCompanion Function({
  required Uint8List id,
  required DateTime createdAt,
  required DateTime modifiedAt,
  required String name,
  required String path,
  Value<Order> order,
  Value<Duration> pomodoro,
  Value<int> rowid,
});
typedef $$ContextsTableUpdateCompanionBuilder = ContextsCompanion Function({
  Value<Uint8List> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<String> name,
  Value<String> path,
  Value<Order> order,
  Value<Duration> pomodoro,
  Value<int> rowid,
});

final class $$ContextsTableReferences
    extends BaseReferences<_$Store, $ContextsTable, Context> {
  $$ContextsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$NotesTable, List<Note>> _notesRefsTable(
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
}

class $$ContextsTableFilterComposer
    extends FilterComposer<_$Store, $ContextsTable> {
  $$ContextsTableFilterComposer(super.$state);
  ColumnFilters<Uint8List> get id => $state.composableBuilder(
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

  ColumnFilters<String> get path => $state.composableBuilder(
      column: $state.table.path,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

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
    Context,
    $$ContextsTableFilterComposer,
    $$ContextsTableOrderingComposer,
    $$ContextsTableCreateCompanionBuilder,
    $$ContextsTableUpdateCompanionBuilder,
    (Context, $$ContextsTableReferences),
    Context,
    PrefetchHooks Function({bool notesRefs})> {
  $$ContextsTableTableManager(_$Store db, $ContextsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          filteringComposer:
              $$ContextsTableFilterComposer(ComposerState(db, table)),
          orderingComposer:
              $$ContextsTableOrderingComposer(ComposerState(db, table)),
          updateCompanionCallback: ({
            Value<Uint8List> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<String> path = const Value.absent(),
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
            required Uint8List id,
            required DateTime createdAt,
            required DateTime modifiedAt,
            required String name,
            required String path,
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
          prefetchHooksCallback: ({notesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (notesRefs) db.notes],
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
    Context,
    $$ContextsTableFilterComposer,
    $$ContextsTableOrderingComposer,
    $$ContextsTableCreateCompanionBuilder,
    $$ContextsTableUpdateCompanionBuilder,
    (Context, $$ContextsTableReferences),
    Context,
    PrefetchHooks Function({bool notesRefs})>;
typedef $$NotesTableCreateCompanionBuilder = NotesCompanion Function({
  required Uint8List id,
  required DateTime createdAt,
  required DateTime modifiedAt,
  required Uint8List userId,
  required String body,
  required double order,
  required bool root,
  required bool private,
  required Uint8List topicId,
  Value<Uint8List?> contextId,
  Value<int> rowid,
});
typedef $$NotesTableUpdateCompanionBuilder = NotesCompanion Function({
  Value<Uint8List> id,
  Value<DateTime> createdAt,
  Value<DateTime> modifiedAt,
  Value<Uint8List> userId,
  Value<String> body,
  Value<double> order,
  Value<bool> root,
  Value<bool> private,
  Value<Uint8List> topicId,
  Value<Uint8List?> contextId,
  Value<int> rowid,
});

final class $$NotesTableReferences
    extends BaseReferences<_$Store, $NotesTable, Note> {
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
  ColumnFilters<Uint8List> get id => $state.composableBuilder(
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

  ColumnFilters<Uint8List> get userId => $state.composableBuilder(
      column: $state.table.userId,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<String> get body => $state.composableBuilder(
      column: $state.table.body,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<double> get order => $state.composableBuilder(
      column: $state.table.order,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get root => $state.composableBuilder(
      column: $state.table.root,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<bool> get private => $state.composableBuilder(
      column: $state.table.private,
      builder: (column, joinBuilders) =>
          ColumnFilters(column, joinBuilders: joinBuilders));

  ColumnFilters<Uint8List> get topicId => $state.composableBuilder(
      column: $state.table.topicId,
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
    Note,
    $$NotesTableFilterComposer,
    $$NotesTableOrderingComposer,
    $$NotesTableCreateCompanionBuilder,
    $$NotesTableUpdateCompanionBuilder,
    (Note, $$NotesTableReferences),
    Note,
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
            Value<Uint8List> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> modifiedAt = const Value.absent(),
            Value<Uint8List> userId = const Value.absent(),
            Value<String> body = const Value.absent(),
            Value<double> order = const Value.absent(),
            Value<bool> root = const Value.absent(),
            Value<bool> private = const Value.absent(),
            Value<Uint8List> topicId = const Value.absent(),
            Value<Uint8List?> contextId = const Value.absent(),
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
            required Uint8List id,
            required DateTime createdAt,
            required DateTime modifiedAt,
            required Uint8List userId,
            required String body,
            required double order,
            required bool root,
            required bool private,
            required Uint8List topicId,
            Value<Uint8List?> contextId = const Value.absent(),
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
    Note,
    $$NotesTableFilterComposer,
    $$NotesTableOrderingComposer,
    $$NotesTableCreateCompanionBuilder,
    $$NotesTableUpdateCompanionBuilder,
    (Note, $$NotesTableReferences),
    Note,
    PrefetchHooks Function({bool contextId})>;

class $StoreManager {
  final _$Store _db;
  $StoreManager(this._db);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db, _db.accounts);
  $$ContextsTableTableManager get contexts =>
      $$ContextsTableTableManager(_db, _db.contexts);
  $$NotesTableTableManager get notes =>
      $$NotesTableTableManager(_db, _db.notes);
}
